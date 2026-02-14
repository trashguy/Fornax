# Task Completion Checklist

After completing a coding task:
1. Run `zig build x86_64` to verify compilation
2. Check for any arch-specific stubs that need updating (aarch64 stubs)
3. User-space programs are embedded as ELF — changes require full rebuild
4. No test framework — verification is via QEMU boot and serial output
