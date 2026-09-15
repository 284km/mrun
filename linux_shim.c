/* linux_shim.c — the Linux calls an OCI runtime makes and Mere does not have.
 *
 * Handles and ints only, the shape the socket family already uses. Two things
 * need a builder rather than a direct call: execve takes char *const[] vectors,
 * which cannot cross the FFI, so argv and envp are pushed one string at a time
 * and consumed by do_execve.
 *
 * Flags are resolved BY NAME (`ns_flag "CLONE_NEWPID"`). Writing 0x20000000 in
 * the Mere source would be a second copy of a number the kernel headers already
 * define, and a copy is a thing that can be wrong on its own.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

static int last_errno = 0;
int lx_errno(void) { return last_errno; }
static int fail(void) { last_errno = errno; return -1; }
static int okay(int v) { last_errno = 0; return v; }

/* ---- flags by name ---------------------------------------------------- */
struct kv { const char *n; unsigned long v; };
static const struct kv FLAGS[] = {
    {"CLONE_NEWNS", CLONE_NEWNS},     {"CLONE_NEWUTS", CLONE_NEWUTS},
    {"CLONE_NEWIPC", CLONE_NEWIPC},   {"CLONE_NEWPID", CLONE_NEWPID},
    {"CLONE_NEWNET", CLONE_NEWNET},   {"CLONE_NEWUSER", CLONE_NEWUSER},
    {"CLONE_NEWCGROUP", CLONE_NEWCGROUP},
    {"MS_RDONLY", MS_RDONLY},         {"MS_NOSUID", MS_NOSUID},
    {"MS_NODEV", MS_NODEV},           {"MS_NOEXEC", MS_NOEXEC},
    {"MS_BIND", MS_BIND},             {"MS_REC", MS_REC},
    {"MS_PRIVATE", MS_PRIVATE},       {"MS_SLAVE", MS_SLAVE},
    {"MS_STRICTATIME", MS_STRICTATIME},
    {"MS_RELATIME", MS_RELATIME},     {"MS_NOATIME", MS_NOATIME},
    {"MS_NODIRATIME", MS_NODIRATIME}, {"MS_SYNCHRONOUS", MS_SYNCHRONOUS},
    {"MS_DIRSYNC", MS_DIRSYNC},       {"MS_REMOUNT", MS_REMOUNT},
    {"MNT_DETACH", MNT_DETACH},
};

/* -1 for a name this table does not have: an unknown mount option must be
 * refused by the caller, never folded into 0 and silently dropped. */
int lx_flag(const char *name) {
    for (unsigned i = 0; i < sizeof FLAGS / sizeof *FLAGS; i++)
        if (strcmp(FLAGS[i].n, name) == 0) return (int)FLAGS[i].v;
    return -1;
}

/* ---- namespaces, process ---------------------------------------------- */
int lx_unshare(int flags) { return unshare(flags) == 0 ? okay(0) : fail(); }
int lx_fork(void)         { int p = (int)fork(); return p < 0 ? fail() : okay(p); }
int lx_setsid(void)       { return setsid() < 0 ? fail() : okay(0); }

int lx_wait(int pid) {
    int st = 0;
    if (waitpid((pid_t)pid, &st, 0) < 0) return fail();
    if (WIFEXITED(st)) return okay(WEXITSTATUS(st));
    if (WIFSIGNALED(st)) return okay(128 + WTERMSIG(st));
    return okay(-2);
}

/* ---- filesystem -------------------------------------------------------- */
int lx_mount(const char *src, const char *tgt, const char *fs, int flags, const char *data) {
    const char *d = (data && data[0]) ? data : NULL;
    const char *f = (fs && fs[0]) ? fs : NULL;
    const char *s = (src && src[0]) ? src : NULL;
    return mount(s, tgt, f, (unsigned long)flags, d) == 0 ? okay(0) : fail();
}
int lx_umount2(const char *t, int flags) { return umount2(t, flags) == 0 ? okay(0) : fail(); }
int lx_mkdir(const char *p, int mode)    { return (mkdir(p, (mode_t)mode) == 0 || errno == EEXIST) ? okay(0) : fail(); }
int lx_chdir(const char *p)              { return chdir(p) == 0 ? okay(0) : fail(); }
int lx_sethostname(const char *n)        { return sethostname(n, strlen(n)) == 0 ? okay(0) : fail(); }

/* No glibc wrapper for pivot_root. */
int lx_pivot_root(const char *newroot, const char *put_old) {
    return syscall(SYS_pivot_root, newroot, put_old) == 0 ? okay(0) : fail();
}

/* ---- argv / envp builders + execve ------------------------------------ */
#define MAXV 256
static char *AV[MAXV + 1]; static int AVn = 0;
static char *EV[MAXV + 1]; static int EVn = 0;

static int push(char **v, int *n, const char *s) {
    if (*n >= MAXV) { last_errno = E2BIG; return -1; }
    v[*n] = strdup(s);
    if (!v[*n]) { last_errno = ENOMEM; return -1; }
    v[++(*n)] = NULL;
    return okay(0);
}
int lx_av_reset(void) { for (int i = 0; i < AVn; i++) free(AV[i]); AVn = 0; AV[0] = NULL; return 0; }
int lx_ev_reset(void) { for (int i = 0; i < EVn; i++) free(EV[i]); EVn = 0; EV[0] = NULL; return 0; }
int lx_av_push(const char *s) { return push(AV, &AVn, s); }
int lx_ev_push(const char *s) { return push(EV, &EVn, s); }

/* Returns only on failure -- the whole point is that it does not return. */
int lx_execve(const char *path) {
    if (AVn == 0) { last_errno = EINVAL; return -1; }
    execve(path, AV, EV);
    return fail();
}

/* ---- stat-ish questions the masked-path rule needs -------------------- */
int lx_exists(const char *p) { struct stat st; return lstat(p, &st) == 0 ? 1 : 0; }
int lx_is_dir(const char *p) { struct stat st; return (stat(p, &st) == 0 && S_ISDIR(st.st_mode)) ? 1 : 0; }
int lx_rmdir(const char *p)  { return rmdir(p) == 0 ? okay(0) : fail(); }

/* Is the host's cgroup tree unified (v2)? A bundle generated by `runc spec`
 * asks for a "cgroup" mount, which is the v1 spelling; on a v2 host runc
 * mounts cgroup2 instead. Asking the filesystem is the only honest way to know
 * which -- the spec cannot say, because it does not know where it will run. */
#include <sys/vfs.h>
#ifndef CGROUP2_SUPER_MAGIC
#define CGROUP2_SUPER_MAGIC 0x63677270
#endif
int lx_cgroup_unified(void) {
    struct statfs sf;
    if (statfs("/sys/fs/cgroup", &sf) != 0) return 0;
    return sf.f_type == CGROUP2_SUPER_MAGIC ? 1 : 0;
}

/* ---- capabilities ------------------------------------------------------ */
#include <linux/capability.h>
#include <sys/prctl.h>

static const struct { const char *n; int v; } CAPS[] = {
    {"CAP_CHOWN",CAP_CHOWN},{"CAP_DAC_OVERRIDE",CAP_DAC_OVERRIDE},
    {"CAP_DAC_READ_SEARCH",CAP_DAC_READ_SEARCH},{"CAP_FOWNER",CAP_FOWNER},
    {"CAP_FSETID",CAP_FSETID},{"CAP_KILL",CAP_KILL},{"CAP_SETGID",CAP_SETGID},
    {"CAP_SETUID",CAP_SETUID},{"CAP_SETPCAP",CAP_SETPCAP},
    {"CAP_LINUX_IMMUTABLE",CAP_LINUX_IMMUTABLE},
    {"CAP_NET_BIND_SERVICE",CAP_NET_BIND_SERVICE},
    {"CAP_NET_BROADCAST",CAP_NET_BROADCAST},{"CAP_NET_ADMIN",CAP_NET_ADMIN},
    {"CAP_NET_RAW",CAP_NET_RAW},{"CAP_IPC_LOCK",CAP_IPC_LOCK},
    {"CAP_IPC_OWNER",CAP_IPC_OWNER},{"CAP_SYS_MODULE",CAP_SYS_MODULE},
    {"CAP_SYS_RAWIO",CAP_SYS_RAWIO},{"CAP_SYS_CHROOT",CAP_SYS_CHROOT},
    {"CAP_SYS_PTRACE",CAP_SYS_PTRACE},{"CAP_SYS_PACCT",CAP_SYS_PACCT},
    {"CAP_SYS_ADMIN",CAP_SYS_ADMIN},{"CAP_SYS_BOOT",CAP_SYS_BOOT},
    {"CAP_SYS_NICE",CAP_SYS_NICE},{"CAP_SYS_RESOURCE",CAP_SYS_RESOURCE},
    {"CAP_SYS_TIME",CAP_SYS_TIME},{"CAP_SYS_TTY_CONFIG",CAP_SYS_TTY_CONFIG},
    {"CAP_MKNOD",CAP_MKNOD},{"CAP_LEASE",CAP_LEASE},
    {"CAP_AUDIT_WRITE",CAP_AUDIT_WRITE},{"CAP_AUDIT_CONTROL",CAP_AUDIT_CONTROL},
    {"CAP_SETFCAP",CAP_SETFCAP},{"CAP_MAC_OVERRIDE",CAP_MAC_OVERRIDE},
    {"CAP_MAC_ADMIN",CAP_MAC_ADMIN},{"CAP_SYSLOG",CAP_SYSLOG},
    {"CAP_WAKE_ALARM",CAP_WAKE_ALARM},{"CAP_BLOCK_SUSPEND",CAP_BLOCK_SUSPEND},
    {"CAP_AUDIT_READ",CAP_AUDIT_READ},
#ifdef CAP_PERFMON
    {"CAP_PERFMON",CAP_PERFMON},{"CAP_BPF",CAP_BPF},
    {"CAP_CHECKPOINT_RESTORE",CAP_CHECKPOINT_RESTORE},
#endif
};

/* Values come from the kernel headers, not transcribed. A name this table does
 * not have returns -1 so the caller refuses the bundle: quietly not granting a
 * capability it asked for is a difference nothing would report. */
static int cap_num(const char *n) {
    for (unsigned i = 0; i < sizeof CAPS / sizeof *CAPS; i++)
        if (strcmp(CAPS[i].n, n) == 0) return CAPS[i].v;
    return -1;
}

static unsigned long long SET[5];   /* eff perm inh bnd amb */
static int set_index(const char *s) {
    if (!strcmp(s,"effective")) return 0;
    if (!strcmp(s,"permitted")) return 1;
    if (!strcmp(s,"inheritable")) return 2;
    if (!strcmp(s,"bounding")) return 3;
    if (!strcmp(s,"ambient")) return 4;
    return -1;
}
int lx_cap_reset(void) { for (int i=0;i<5;i++) SET[i]=0; return 0; }
int lx_cap_add(const char *set, const char *cap) {
    int si = set_index(set), c = cap_num(cap);
    if (si < 0 || c < 0) { last_errno = EINVAL; return -1; }
    SET[si] |= 1ULL << c;
    return 0;
}

int lx_cap_apply(void) {
    /* Bounding first, while CAP_SETPCAP is still held. */
    for (int c = 0; c <= CAP_LAST_CAP; c++)
        if (!(SET[3] & (1ULL << c)))
            if (prctl(PR_CAPBSET_DROP, c, 0, 0, 0) != 0 && errno != EINVAL) return fail();

    struct __user_cap_header_struct hdr = { _LINUX_CAPABILITY_VERSION_3, 0 };
    struct __user_cap_data_struct d[2];
    memset(d, 0, sizeof d);
    for (int i = 0; i < 2; i++) {
        d[i].effective   = (__u32)(SET[0] >> (32 * i));
        d[i].permitted   = (__u32)(SET[1] >> (32 * i));
        d[i].inheritable = (__u32)(SET[2] >> (32 * i));
    }
    if (syscall(SYS_capset, &hdr, d) != 0) return fail();

    for (int c = 0; c <= CAP_LAST_CAP; c++)
        if (SET[4] & (1ULL << c))
            if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_RAISE, c, 0, 0) != 0) return fail();
    return okay(0);
}

/* ---- device nodes ------------------------------------------------------ */
#include <sys/sysmacros.h>   /* makedev; split out of sys/types.h in glibc 2.28 */
/* The container's /dev is a fresh tmpfs, so the nodes every container is
 * expected to have do not exist until something makes them. The major/minor
 * pairs live in the Mere caller, where the runtime-spec's default device list
 * is; this only performs the call, because encoding a dev_t is libc's job and
 * not a number worth writing out. */
int lx_mknod(const char *path, int mode, int major_, int minor_) {
    if (mknod(path, (mode_t)mode, makedev((unsigned)major_, (unsigned)minor_)) == 0) return okay(0);
    return errno == EEXIST ? okay(0) : fail();
}
int lx_symlink_at(const char *target, const char *path) {
    if (symlink(target, path) == 0) return okay(0);
    return errno == EEXIST ? okay(0) : fail();
}

/* Is this path an executable file? For resolving argv[0] against PATH. */
int lx_can_exec(const char *p) { return access(p, X_OK) == 0 ? 1 : 0; }
