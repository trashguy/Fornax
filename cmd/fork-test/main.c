/*
 * fork-test — POSIX process model verification for Fornax.
 *
 * Tests:
 *   1. fork() → child gets pid 0, parent gets child pid
 *   2. waitpid() → parent reaps child with correct exit status
 *   3. fork() + execve() → child replaces image
 *   4. pipe() + fork() → parent/child communicate via pipe
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#include <string.h>

static void test_basic_fork(void)
{
    printf("=== Test 1: basic fork ===\n");
    pid_t pid = fork();
    if (pid < 0) {
        printf("FAIL: fork() returned %d\n", pid);
        return;
    }
    if (pid == 0) {
        /* child */
        printf("  child: pid=%d ppid=%d\n", getpid(), getppid());
        _exit(42);
    }
    /* parent */
    int status;
    pid_t reaped = waitpid(pid, &status, 0);
    printf("  parent: fork returned %d, waitpid returned %d\n", pid, reaped);
    if (WIFEXITED(status)) {
        printf("  child exited with status %d\n", WEXITSTATUS(status));
        if (WEXITSTATUS(status) == 42)
            printf("  PASS\n");
        else
            printf("  FAIL: expected 42\n");
    } else {
        printf("  FAIL: child did not exit normally\n");
    }
}

static void test_fork_exec(void)
{
    printf("=== Test 2: fork + exec ===\n");
    pid_t pid = fork();
    if (pid < 0) {
        printf("FAIL: fork() returned %d\n", pid);
        return;
    }
    if (pid == 0) {
        /* child: exec echo */
        char *argv[] = { "echo", "hello from exec", NULL };
        execve("/bin/echo", argv, NULL);
        /* if we get here, exec failed */
        printf("  FAIL: execve failed\n");
        _exit(1);
    }
    int status;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0)
        printf("  PASS\n");
    else
        printf("  FAIL: exec'd child status=%d\n", status);
}

static void test_multi_fork(void)
{
    printf("=== Test 3: multi-fork ===\n");
    int i;
    for (i = 0; i < 3; i++) {
        pid_t pid = fork();
        if (pid == 0) {
            printf("  child %d: pid=%d\n", i, getpid());
            _exit(i);
        }
    }
    /* wait for all */
    int reaped = 0;
    for (i = 0; i < 3; i++) {
        int status;
        pid_t w = wait(&status);
        if (w > 0) reaped++;
    }
    printf("  reaped %d children\n", reaped);
    if (reaped == 3)
        printf("  PASS\n");
    else
        printf("  FAIL\n");
}

static void test_pipe_fork(void)
{
    printf("=== Test 4: pipe + fork ===\n");
    int pipefd[2];
    if (pipe(pipefd) < 0) {
        printf("  FAIL: pipe() failed\n");
        return;
    }

    pid_t pid = fork();
    if (pid == 0) {
        /* child: write to pipe */
        close(pipefd[0]);
        const char *msg = "hello pipe";
        write(pipefd[1], msg, strlen(msg));
        close(pipefd[1]);
        _exit(0);
    }

    /* parent: read from pipe */
    close(pipefd[1]);
    char buf[64];
    int n = read(pipefd[0], buf, sizeof(buf) - 1);
    close(pipefd[0]);

    int status;
    waitpid(pid, &status, 0);

    if (n > 0) {
        buf[n] = '\0';
        printf("  read from pipe: \"%s\"\n", buf);
        if (strcmp(buf, "hello pipe") == 0)
            printf("  PASS\n");
        else
            printf("  FAIL: wrong data\n");
    } else {
        printf("  FAIL: read returned %d\n", n);
    }
}

int main(void)
{
    printf("fork-test: POSIX process model tests\n\n");
    test_basic_fork();
    printf("\n");
    test_fork_exec();
    printf("\n");
    test_multi_fork();
    printf("\n");
    test_pipe_fork();
    printf("\nAll tests complete.\n");
    return 0;
}
