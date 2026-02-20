/* syscall_arch.h — Fornax override for musl's x86_64 syscall routing.
 *
 * Instead of raw SYSCALL instructions, all musl __syscall calls go through
 * __fornax_syscall() which translates Linux syscall numbers to Fornax.
 */

#define __SYSCALL_LL_E(x) (x)
#define __SYSCALL_LL_O(x) (x)

long __fornax_syscall(long n, long a, long b, long c, long d, long e, long f);

static __inline long __syscall0(long n)
{
	return __fornax_syscall(n,0,0,0,0,0,0);
}

static __inline long __syscall1(long n, long a)
{
	return __fornax_syscall(n,a,0,0,0,0,0);
}

static __inline long __syscall2(long n, long a, long b)
{
	return __fornax_syscall(n,a,b,0,0,0,0);
}

static __inline long __syscall3(long n, long a, long b, long c)
{
	return __fornax_syscall(n,a,b,c,0,0,0);
}

static __inline long __syscall4(long n, long a, long b, long c, long d)
{
	return __fornax_syscall(n,a,b,c,d,0,0);
}

static __inline long __syscall5(long n, long a, long b, long c, long d, long e)
{
	return __fornax_syscall(n,a,b,c,d,e,0);
}

static __inline long __syscall6(long n, long a, long b, long c, long d, long e, long f)
{
	return __fornax_syscall(n,a,b,c,d,e,f);
}

#define VDSO_USEFUL
#define VDSO_CGT_SYM ""
#define VDSO_CGT_VER ""
