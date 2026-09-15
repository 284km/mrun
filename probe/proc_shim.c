/* probe/proc_shim.c — the smallest process-control surface P1 needs.
 *
 * Mere's FFI cannot pass a `char *const argv[]`, so execv's argument vector is
 * built here. Everything crosses the boundary as C `int` / `const char *`,
 * which is the shape the socket family already uses.
 */
#include <unistd.h>
#include <sys/wait.h>

int proc_fork(void) { return (int)fork(); }

int proc_getpid(void) { return (int)getpid(); }

/* execv with up to two arguments after argv[0]. "" means absent. */
int proc_exec2(const char *path, const char *a1, const char *a2) {
    char *argv[4];
    int n = 0;
    argv[n++] = (char *)path;
    if (a1 && a1[0]) argv[n++] = (char *)a1;
    if (a2 && a2[0]) argv[n++] = (char *)a2;
    argv[n] = 0;
    execv(path, argv);
    return -1;                  /* reached only when execv failed */
}

/* Wait for one child. Its exit status, or -1 (waitpid failed) / -2 (signal). */
int proc_wait(int pid) {
    int st = 0;
    if (waitpid((pid_t)pid, &st, 0) < 0) return -1;
    if (WIFEXITED(st)) return WEXITSTATUS(st);
    return -2;
}

/* _exit, not exit: the child must NOT flush stdio buffers it inherited. */
int proc_exit(int code) { _exit(code); return 0; }
