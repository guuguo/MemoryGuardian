#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--owner") == 0) {
        pid_t child = fork();
        if (child < 0) return 2;
        if (child == 0) {
            close(STDIN_FILENO);
            close(STDOUT_FILENO);
            execl(argv[2], argv[2], (char *)NULL);
            _exit(3);
        }
        printf("%d\n", child);
        fflush(stdout);
        char command;
        read(STDIN_FILENO, &command, 1);
        return 0;
    }
    for (;;) pause();
}
