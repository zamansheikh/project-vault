// ProjectVaultAgent: the program the launchd job (com.projectvault.sync) starts
// every 15 minutes. It runs `zsh <its arguments>`, which install.sh sets to
// `<install dir>/vault sync --quiet`.
//
// It exists so that macOS privacy permissions (Full Disk Access, if your
// projects folder ever needs it) can be given to this one small program
// instead of to /bin/zsh. install.sh and `vault start` build it with:
//   xcrun clang -O2 -o ProjectVaultAgent ProjectVaultAgent.c
// Rebuilding changes its signature, so such a permission must then be granted again.
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>

extern char **environ;

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: ProjectVaultAgent <script> [arguments...]\n");
        return 2;
    }
    char **args = calloc((size_t)argc + 1, sizeof(char *));
    if (!args) return 1;
    args[0] = "/bin/zsh";
    for (int i = 1; i < argc; i++) args[i] = argv[i];
    args[argc] = NULL;

    // Spawn (not exec) so zsh runs as this program's child and macOS checks
    // this program's permissions, not zsh's.
    pid_t pid;
    int rc = posix_spawn(&pid, "/bin/zsh", NULL, NULL, args, environ);
    if (rc != 0) { fprintf(stderr, "ProjectVaultAgent: cannot start zsh: %s\n", strerror(rc)); return 1; }

    int status;
    if (waitpid(pid, &status, 0) < 0) { perror("ProjectVaultAgent: waitpid"); return 1; }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
