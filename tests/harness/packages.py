"""Package builder and HTTP server for fay package manager tests."""
import hashlib
import http.server
import io
import json
import os
import tarfile
import threading

from .config import log, YELLOW


def build_xxd_package(xxd_binary_path, pkg_dir):
    """Create xxd-1.0.0-1.tar.gz with .PKGINFO and bin/xxd."""
    pkg_name = "xxd"
    pkg_ver = "1.0.0-1"
    tarball_name = f"{pkg_name}-{pkg_ver}.tar.gz"
    tarball_path = os.path.join(pkg_dir, tarball_name)

    pkginfo = json.dumps({
        "name": pkg_name,
        "version": pkg_ver,
        "description": "Hex dump and reverse hex dump utility",
        "depends": [],
    }).encode()

    with tarfile.open(tarball_path, "w:gz", format=tarfile.USTAR_FORMAT) as tf:
        # .PKGINFO
        info = tarfile.TarInfo(name=".PKGINFO")
        info.size = len(pkginfo)
        info.type = tarfile.REGTYPE
        tf.addfile(info, io.BytesIO(pkginfo))

        # bin/ directory
        dir_info = tarfile.TarInfo(name="bin/")
        dir_info.type = tarfile.DIRTYPE
        dir_info.mode = 0o755
        tf.addfile(dir_info)

        # bin/xxd
        tf.add(xxd_binary_path, arcname="bin/xxd")

    # Compute SHA-256
    sha256 = hashlib.sha256()
    with open(tarball_path, "rb") as f:
        while True:
            chunk = f.read(8192)
            if not chunk:
                break
            sha256.update(chunk)

    return tarball_name, sha256.hexdigest()


def generate_repo_json(pkg_dir, tarball_name, sha256_hex):
    """Generate repo.json for the test package repository."""
    repo = {
        "packages": {
            "xxd": {
                "version": "1.0.0-1",
                "description": "Hex dump and reverse hex dump utility",
                "url": f"/{tarball_name}",
                "sha256": sha256_hex,
                "depends": [],
            }
        }
    }
    repo_path = os.path.join(pkg_dir, "repo.json")
    with open(repo_path, "w") as f:
        json.dump(repo, f, indent=2)
    return repo_path


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        log("HTTP", fmt % args, YELLOW)


def start_http_server(directory, port=8000):
    """Start a daemon HTTP server serving files from directory."""
    handler = lambda *a, **kw: QuietHandler(*a, directory=directory, **kw)
    http.server.HTTPServer.allow_reuse_address = True
    server = http.server.HTTPServer(("0.0.0.0", port), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server
