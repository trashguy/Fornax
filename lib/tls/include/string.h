/* Minimal string.h for freestanding BearSSL compilation.
 * memcpy/memset/memmove/memcmp are provided by Zig's compiler-rt.
 * strlen is provided by lib/tls/stubs.c.
 */
#ifndef _FORNAX_STRING_H
#define _FORNAX_STRING_H

#include <stddef.h>

void *memcpy(void *dest, const void *src, size_t n);
void *memmove(void *dest, const void *src, size_t n);
void *memset(void *dest, int c, size_t n);
int memcmp(const void *s1, const void *s2, size_t n);
size_t strlen(const char *s);

#endif
