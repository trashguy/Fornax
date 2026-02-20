#include <stdio.h>

int main(int argc, char **argv) {
    printf("Hello POSIX!\n");

    if (argc > 1) {
        printf("args:");
        for (int i = 1; i < argc; i++) {
            printf(" %s", argv[i]);
        }
        printf("\n");
    }

    return 0;
}
