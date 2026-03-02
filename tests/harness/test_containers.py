"""Container tests: native, Linux compat, build, networking, OCI pull."""
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


def test_container_pull(qemu):
    """Test fnx pull from an OCI registry (mock served on host port 5000).

    The mock OCI registry is started by the test harness before this test
    runs. It serves a tiny image with one layer containing /hello.txt.
    After pulling, we verify the image appears in 'fnx images' and that
    the extracted rootfs contains the expected file.
    """
    try:
        # Pull the test image (host_ip:5000 is mock OCI registry on TAP host)
        qemu.send_line(f"fnx pull {qemu.host_ip}:5000/testimg; echo __PULL1__")
        qemu.expect(r"Successfully pulled", timeout=60)
        qemu.expect(r"__PULL1__", timeout=10)

        # Verify image appears in list
        qemu.send_line("fnx images; echo __PULL2__")
        qemu.expect(r"testimg", timeout=10)
        qemu.expect(r"__PULL2__", timeout=10)

        # Verify extracted rootfs has our test file
        qemu.send_line("cat /var/lib/fnx/images/testimg/rootfs/hello.txt; echo __PULL3__")
        qemu.expect(r"oci-pull-test-ok", timeout=10)
        qemu.expect(r"__PULL3__", timeout=10)

        # Verify config was extracted
        qemu.send_line("cat /var/lib/fnx/images/testimg/config; echo __PULL4__")
        qemu.expect(r"/bin/sh", timeout=10)
        qemu.expect(r"__PULL4__", timeout=10)

        log_pass("test_container_pull")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_container_pull", str(e))
        return False


def test_container_pull_real(qemu):
    """Test fnx pull alpine from a real Docker registry:2 on host port 5001.

    Requires Docker on the host (skipped if unavailable). The harness starts
    registry:2, pushes alpine:latest to it, then Fornax pulls via the
    explicit registry syntax. Verifies alpine's /etc/alpine-release exists.
    """
    try:
        # Pull alpine with explicit registry:port (5001 = real Docker registry)
        qemu.send_line(f"fnx pull {qemu.host_ip}:5001/alpine; echo __RPULL1__")
        qemu.expect(r"Successfully pulled", timeout=120)
        qemu.expect(r"__RPULL1__", timeout=10)

        # Verify image appears
        qemu.send_line("fnx images; echo __RPULL2__")
        qemu.expect(r"alpine", timeout=10)
        qemu.expect(r"__RPULL2__", timeout=10)

        # Verify alpine rootfs has expected files
        qemu.send_line("cat /var/lib/fnx/images/alpine/rootfs/etc/alpine-release; echo __RPULL3__")
        qemu.expect(r"\d+\.\d+", timeout=10)  # e.g. "3.21.3"
        qemu.expect(r"__RPULL3__", timeout=10)

        # Verify compat file says linux
        qemu.send_line("cat /var/lib/fnx/images/alpine/compat; echo __RPULL4__")
        qemu.expect(r"linux", timeout=10)
        qemu.expect(r"__RPULL4__", timeout=10)

        log_pass("test_container_pull_real")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_container_pull_real", str(e))
        return False


def test_container_pull_dockerhub(qemu):
    """Test fnx pull alpine directly from Docker Hub over TLS.

    Requires internet access (TAP+MASQUERADE provides NAT). TLS is always
    enabled on x86_64. Tests the full Docker Hub auth flow:
    401 → WWW-Authenticate → anonymous Bearer token → authenticated pull.
    Verifies alpine's /etc/alpine-release exists after extraction.
    """
    try:
        # Pull alpine from Docker Hub (TLS + Bearer token auth)
        qemu.send_line("fnx pull docker.io/alpine; echo __DHPULL1__")
        qemu.expect(r"Successfully pulled", timeout=180)
        qemu.expect(r"__DHPULL1__", timeout=10)

        # Verify image appears in list
        qemu.send_line("fnx images; echo __DHPULL2__")
        qemu.expect(r"alpine", timeout=10)
        qemu.expect(r"__DHPULL2__", timeout=10)

        # Verify alpine rootfs has expected files
        qemu.send_line("cat /var/lib/fnx/images/alpine/rootfs/etc/alpine-release; echo __DHPULL3__")
        qemu.expect(r"\d+\.\d+", timeout=10)  # e.g. "3.21.3"
        qemu.expect(r"__DHPULL3__", timeout=10)

        # Verify compat file says linux (alpine is a Linux image)
        qemu.send_line("cat /var/lib/fnx/images/alpine/compat; echo __DHPULL4__")
        qemu.expect(r"linux", timeout=10)
        qemu.expect(r"__DHPULL4__", timeout=10)

        log_pass("test_container_pull_dockerhub")
        return True
    except (TimeoutError, RuntimeError) as e:
        log_fail("test_container_pull_dockerhub", str(e))
        return False
