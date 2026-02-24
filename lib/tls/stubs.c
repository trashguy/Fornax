/* Minimal C stubs for freestanding BearSSL.
 *
 * memcpy/memset/memmove/memcmp are provided by Zig's compiler-rt.
 * Only strlen needs an explicit implementation.
 */
#include <stddef.h>

size_t strlen(const char *s)
{
	size_t n = 0;
	while (s[n] != '\0')
		n++;
	return n;
}
