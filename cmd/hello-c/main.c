#include <fornax.h>

int main(int argc, char **argv) {
    fx_write(1, "Hello from C!\n", 14);

    if (argc > 1) {
        fx_puts(1, "args:");
        for (int i = 1; i < argc; i++) {
            fx_write(1, " ", 1);
            fx_puts(1, argv[i]);
        }
        fx_write(1, "\n", 1);
    }

    return 0;
}
