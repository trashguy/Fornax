#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    printf("malloc test: allocating...\n");

    /* Test 1: small allocation */
    char *p1 = malloc(64);
    if (!p1) { printf("FAIL: malloc(64)\n"); return 1; }
    memset(p1, 'A', 64);
    printf("  64 bytes: OK\n");

    /* Test 2: medium allocation */
    char *p2 = malloc(4096);
    if (!p2) { printf("FAIL: malloc(4096)\n"); return 1; }
    memset(p2, 'B', 4096);
    printf("  4096 bytes: OK\n");

    /* Test 3: large allocation */
    char *p3 = malloc(65536);
    if (!p3) { printf("FAIL: malloc(65536)\n"); return 1; }
    memset(p3, 'C', 65536);
    printf("  65536 bytes: OK\n");

    /* Test 4: free and re-allocate */
    free(p1);
    free(p2);
    free(p3);

    char *p4 = malloc(128);
    if (!p4) { printf("FAIL: realloc after free\n"); return 1; }
    memset(p4, 'D', 128);
    printf("  realloc after free: OK\n");

    free(p4);
    printf("malloc test: PASS\n");
    return 0;
}
