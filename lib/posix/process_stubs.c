/* process_stubs.c — Simple fork/waitpid/_exit for Fornax POSIX realm.
 *
 * musl's fork.c pulls in signal-blocking internals we don't support.
 * These wrappers call the shim directly via __fornax_syscall, using
 * the same syscall numbers as the overlay (x86_64 ABI on all arches).
 */
#include <unistd.h>
#include <sys/wait.h>
#include <sys/syscall.h>

long __fornax_syscall(long, ...);

pid_t fork(void)
{
    return __fornax_syscall(SYS_fork);
}

pid_t waitpid(pid_t pid, int *status, int options)
{
    return __fornax_syscall(SYS_wait4, pid, (long)status, options, 0);
}

void _exit(int status)
{
    __fornax_syscall(SYS_exit_group, status);
    __builtin_unreachable();
}

pid_t wait(int *status)
{
    return waitpid(-1, status, 0);
}
