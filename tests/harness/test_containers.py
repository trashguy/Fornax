"""Container tests: native, Linux compat, build, networking."""
import time

from .config import log_pass, log_fail


def test_container_native(qemu):
    """Test a native Fornax container running echo."""
    try:
        # Create image directory structure
        qemu.send_cmd("mkdir -p /var/lib/fnx/images/hello/rootfs/bin")
        qemu.send_cmd("mkdir -p /var/lib/fnx/containers")

        # Copy echo and cat binaries into image rootfs
        qemu.send_cmd("cp /bin/echo /var/lib/fnx/images/hello/rootfs/bin/echo")
        qemu.send_cmd("cp /bin/cat /var/lib/fnx/images/hello/rootfs/bin/cat")

        # Run container — echo writes to console and exits
        # Match \nhello-from-container to avoid false-positive on shell echo
        qemu.send_line("fnx run --name test-hello hello /bin/echo hello-from-container; echo __CNTR1__")
        qemu.expect(r"\nhello-from-container", timeout=30)
        qemu.expect(r"__CNTR1__\r?\n", timeout=15)

        # Verify fnx ps shows nothing running (container already exited)
        qemu.send_line("fnx ps; echo __PS1__")
        qemu.expect(r"__PS1__", timeout=10)

        log_pass("test_container_native")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_container_native", str(e))
        return False


def test_container_linux_compat(qemu):
    """Test Linux syscall compatibility layer with a minimal static ELF.

    A hand-crafted Linux x86_64 binary (pre-staged at /tmp/hello-linux)
    uses Linux syscall numbers (write=1, exit=60). The kernel's
    linux_compat.zig translates these to Fornax handlers at runtime.
    """
    try:
        # Create image with the pre-staged Linux binary
        qemu.send_cmd("mkdir -p /var/lib/fnx/images/linux-test/rootfs/bin")
        qemu.send_cmd("cp /tmp/hello-linux /var/lib/fnx/images/linux-test/rootfs/bin/hello")

        # Run with Linux compat mode
        qemu.send_line("fnx run --compat linux --name test-linux linux-test /bin/hello; echo __CNTR2__")
        qemu.expect(r"hello-linux-compat", timeout=30)
        qemu.expect(r"__CNTR2__", timeout=15)

        log_pass("test_container_linux_compat")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_container_linux_compat", str(e))
        return False


def test_container_build(qemu):
    """Test fnx build from a Containerfile.

    Depends on test_container_native having created the 'hello' image.
    Writes a Containerfile with FROM + COPY + CMD, builds an image,
    then runs it and verifies output.
    """
    try:
        # Create build context with a test file (pre-staged at /tmp/build-ctx/)
        qemu.send_cmd("mkdir -p /tmp/build-ctx")
        qemu.send_cmd("echo build-output-ok > /tmp/build-ctx/msg.txt")

        # Write Containerfile using >> append
        qemu.send_cmd("echo FROM hello > /tmp/Containerfile")
        qemu.send_cmd("echo COPY msg.txt /tmp/msg.txt >> /tmp/Containerfile")
        qemu.send_cmd("echo CMD /bin/cat /tmp/msg.txt >> /tmp/Containerfile")

        # Diagnostic: verify file exists and has content
        qemu.send_line("ls /tmp/; echo __DIAG1__")
        qemu.expect(r"__DIAG1__", timeout=10)
        qemu.send_line("cat /tmp/Containerfile; echo __DIAG2__")
        qemu.expect(r"__DIAG2__", timeout=10)

        # Build image
        qemu.send_line("fnx build -f /tmp/Containerfile -t myapp /tmp/build-ctx; echo __BUILD1__")
        qemu.expect(r"Successfully built image", timeout=60)
        qemu.expect(r"__BUILD1__", timeout=10)

        # Run the built image (CMD = /bin/cat /tmp/msg.txt)
        # Wait for prompt to be ready (avoid IRQ messages corrupting input)
        time.sleep(0.5)
        qemu.send_line("fnx run --name test-build myapp; echo __BUILD2__")
        qemu.expect(r"build-output-ok", timeout=30)
        qemu.expect(r"__BUILD2__", timeout=15)

        log_pass("test_container_build")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_container_build", str(e))
        return False


def test_container_networking(qemu):
    """Test container networking: netd spawn + IPC /net/ access from container.

    Creates a long-running container (cat blocks on stdin), then uses
    fnx exec to run 'ip' inside it, verifying the container's own netd
    responds via IPC.
    """
    try:
        # Create image with networking test binaries
        qemu.send_cmd("mkdir -p /var/lib/fnx/images/netimg/rootfs/bin")
        qemu.send_cmd("cp /bin/cat /var/lib/fnx/images/netimg/rootfs/bin/cat")
        qemu.send_cmd("cp /bin/ip /var/lib/fnx/images/netimg/rootfs/bin/ip")
        qemu.send_cmd("cp /bin/echo /var/lib/fnx/images/netimg/rootfs/bin/echo")

        # Run container detached — cat (no args) blocks on stdin forever
        qemu.send_line("fnx run -d --name net-box netimg /bin/cat; echo __NETRUN__")
        # Verify netd was spawned for the container
        qemu.expect(r"netd pid=\d+", timeout=30)
        qemu.expect(r"__NETRUN__", timeout=10)

        # Give container netd time to enter its IPC loop
        time.sleep(2)

        # Execute ip command inside container — reads /net/status via container's netd
        qemu.send_line("fnx exec net-box /bin/ip; echo __NETEXEC__")
        qemu.expect(r"(mac|ip|gateway)", timeout=20)
        qemu.expect(r"__NETEXEC__", timeout=10)

        # Verify container is still running
        qemu.send_line("fnx ps; echo __NETPS__")
        qemu.expect(r"net-box", timeout=10)
        qemu.expect(r"__NETPS__", timeout=5)

        # Cleanup
        qemu.send_cmd("fnx stop net-box", timeout=10)
        qemu.send_cmd("fnx rm net-box", timeout=10)

        log_pass("test_container_networking")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_container_networking", str(e))
        return False
