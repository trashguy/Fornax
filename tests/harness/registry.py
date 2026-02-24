"""OCI registry helpers: mock registry for unit tests + real Docker registry for integration.

Mock registry:
  Serves a tiny OCI image with one gzipped tar layer containing /hello.txt.
  Implements the minimal Docker Registry v2 API surface that fnx pull needs.

Real registry:
  Starts a Docker registry:2 container, pushes alpine to it, cleans up after.
  Requires Docker to be installed and running on the host.
"""
import gzip
import hashlib
import http.server
import io
import json
import os
import shutil
import subprocess
import tarfile
import threading
import time

from .config import log, YELLOW, RED, RESET


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def build_test_image():
    """Build a minimal OCI image (config + one layer) in memory.

    Returns dict mapping "sha256:<hex>" digests to bytes, plus the
    manifest JSON bytes and its digest.
    """
    blobs = {}

    # Layer: gzipped tar with /hello.txt
    tar_buf = io.BytesIO()
    with tarfile.open(fileobj=tar_buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        data = b"oci-pull-test-ok\n"
        info = tarfile.TarInfo(name="hello.txt")
        info.size = len(data)
        info.mode = 0o644
        info.uid = 0
        info.gid = 0
        tf.addfile(info, io.BytesIO(data))
    tar_bytes = tar_buf.getvalue()

    gz_buf = io.BytesIO()
    with gzip.GzipFile(fileobj=gz_buf, mode="wb") as gz:
        gz.write(tar_bytes)
    layer_bytes = gz_buf.getvalue()
    layer_digest = f"sha256:{_sha256(layer_bytes)}"
    blobs[layer_digest] = layer_bytes

    # Config JSON (minimal OCI image config)
    config = {
        "architecture": "amd64",
        "os": "linux",
        "config": {
            "Entrypoint": ["/bin/sh"],
            "Cmd": [],
            "Env": ["PATH=/bin"],
        },
        "rootfs": {
            "type": "layers",
            "diff_ids": [f"sha256:{_sha256(tar_bytes)}"],
        },
    }
    config_bytes = json.dumps(config).encode()
    config_digest = f"sha256:{_sha256(config_bytes)}"
    blobs[config_digest] = config_bytes

    # Manifest
    manifest = {
        "schemaVersion": 2,
        "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
        "config": {
            "mediaType": "application/vnd.docker.container.image.v1+json",
            "size": len(config_bytes),
            "digest": config_digest,
        },
        "layers": [
            {
                "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
                "size": len(layer_bytes),
                "digest": layer_digest,
            },
        ],
    }
    manifest_bytes = json.dumps(manifest).encode()
    manifest_digest = f"sha256:{_sha256(manifest_bytes)}"

    return blobs, manifest_bytes, manifest_digest


class OCIRegistryHandler(http.server.BaseHTTPRequestHandler):
    """Minimal OCI Distribution API handler."""

    # Class-level state set by start_mock_registry()
    blobs = {}
    manifest_bytes = b""
    image_name = "testimg"

    def log_message(self, fmt, *args):
        log("REGISTRY", fmt % args, YELLOW)

    def do_GET(self):
        path = self.path

        # GET /v2/ — registry version check
        if path == "/v2/" or path == "/v2":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Docker-Distribution-Api-Version", "registry/2.0")
            self.end_headers()
            self.wfile.write(b"{}")
            return

        # GET /v2/<name>/manifests/<tag>
        # Accept any name/tag — we only have one image
        if "/manifests/" in path:
            self.send_response(200)
            self.send_header("Content-Type",
                             "application/vnd.docker.distribution.manifest.v2+json")
            self.send_header("Content-Length", str(len(self.manifest_bytes)))
            self.end_headers()
            self.wfile.write(self.manifest_bytes)
            return

        # GET /v2/<name>/blobs/<digest>
        if "/blobs/" in path:
            # Extract digest from path (last component)
            digest = path.split("/blobs/")[-1]
            if digest in self.blobs:
                blob = self.blobs[digest]
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(len(blob)))
                self.end_headers()
                self.wfile.write(blob)
                return
            self.send_response(404)
            self.end_headers()
            return

        # Anything else
        self.send_response(404)
        self.end_headers()


def start_mock_registry(port=5000):
    """Start a mock OCI registry on the given port.

    Returns the HTTPServer instance (call .shutdown() to stop).
    """
    blobs, manifest_bytes, _ = build_test_image()

    OCIRegistryHandler.blobs = blobs
    OCIRegistryHandler.manifest_bytes = manifest_bytes

    http.server.HTTPServer.allow_reuse_address = True
    server = http.server.HTTPServer(("0.0.0.0", port), OCIRegistryHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


# ── Real container registry helpers (podman or docker) ───────────────

REAL_REGISTRY_NAME = "fornax-test-registry"
REAL_REGISTRY_PORT = 5001

# Resolved at runtime by container_engine()
_engine = None


def container_engine():
    """Return 'podman' or 'docker', whichever is available. None if neither."""
    global _engine
    if _engine is not None:
        return _engine
    for cmd in ("podman", "docker"):
        if shutil.which(cmd):
            try:
                result = subprocess.run(
                    [cmd, "info"],
                    capture_output=True, timeout=10,
                )
                if result.returncode == 0:
                    _engine = cmd
                    return _engine
            except (subprocess.TimeoutExpired, OSError):
                continue
    return None


def docker_available():
    """Check if a container engine (podman or docker) is available."""
    return container_engine() is not None


def _run(args, **kwargs):
    """Run a container engine command using the detected engine."""
    eng = container_engine()
    return subprocess.run([eng] + args, **kwargs)


def start_real_registry(port=REAL_REGISTRY_PORT):
    """Start a registry:2 container and push alpine to it.

    Uses podman or docker, whichever is available.
    Returns True if the registry was started and alpine was pushed.
    Caller must call stop_real_registry() to clean up.
    """
    eng = container_engine()
    if not eng:
        return False

    log("REGISTRY", f"Using {eng} for real registry")

    # Remove any stale container from a previous run
    _run(["rm", "-f", REAL_REGISTRY_NAME], capture_output=True)

    # Start registry:2
    # For podman with --tls-verify=false support on push, we need an
    # insecure local registry. Both podman and docker handle localhost
    # registries as insecure by default.
    result = _run(
        ["run", "-d", "-p", f"{port}:5000",
         "--name", REAL_REGISTRY_NAME, "docker.io/library/registry:2"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        log("REGISTRY", f"Failed to start registry:2: {result.stderr.strip()}", RED)
        return False

    # Wait for registry to be ready
    for _ in range(30):
        try:
            import urllib.request
            urllib.request.urlopen(f"http://localhost:{port}/v2/", timeout=1)
            break
        except Exception:
            time.sleep(0.5)
    else:
        log("REGISTRY", "Registry failed to become ready", RED)
        stop_real_registry()
        return False

    # Pull alpine (may already be cached locally)
    log("REGISTRY", "Pulling alpine:latest...")
    result = _run(
        ["pull", "docker.io/library/alpine:latest"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        log("REGISTRY", f"Failed to pull alpine: {result.stderr.strip()}", RED)
        stop_real_registry()
        return False

    # Tag and push to local registry
    local_tag = f"localhost:{port}/alpine:latest"
    _run(["tag", "docker.io/library/alpine:latest", local_tag],
         capture_output=True, check=True)

    log("REGISTRY", f"Pushing alpine to localhost:{port}...")
    push_args = ["push"]
    if eng == "podman":
        push_args.append("--tls-verify=false")
    push_args.append(local_tag)
    result = _run(push_args, capture_output=True, text=True)
    if result.returncode != 0:
        log("REGISTRY", f"Failed to push: {result.stderr.strip()}", RED)
        stop_real_registry()
        return False

    log("REGISTRY", f"Real registry ready on :{port} with alpine:latest")
    return True


def stop_real_registry():
    """Stop and remove the registry container."""
    eng = container_engine()
    if eng:
        subprocess.run([eng, "rm", "-f", REAL_REGISTRY_NAME],
                       capture_output=True)
