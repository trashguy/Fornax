# fay — Fornax Package Manager

## Overview

`fay` is the package manager for Fornax. It follows a subcommand-style CLI in keeping with the Plan 9 ethos: simple, composable, no magic.

The package ecosystem has three components:

- **`fay`** — on-device CLI tool (native Zig, `cmd/fay/`)
- **`fay-build`** — host-side build tool (cross-compiles packages, `tools/fay-build/`)
- **`fornax-ports`** — package definitions repo (`../fornax-ports/`)

## Commands

```
fay sync                    # download repo.json from server
fay install <pkg> [pkg...]  # resolve deps, download, verify, install
fay install --build <pkg>   # build from source locally instead
fay remove <pkg>            # uninstall package
fay upgrade                 # sync + upgrade all installed packages
fay search <term>           # search package descriptions
fay list                    # list installed packages
fay info <pkg>              # show package details
```

## How it works

### Install flow

```
fay install lua
  1. Read /var/lib/fay/sync/repo.json (run fay sync first)
  2. Look up "lua" → get URL, sha256, depends
  3. Resolve dependencies recursively
  4. For each package (deps first):
     a. Download .tar.gz from server
     b. Verify SHA-256 checksum
     c. Extract to / (files go to /bin, /lib, /etc, etc.)
     d. Record installed files in /var/lib/fay/local/<pkg>/files
     e. Save package info to /var/lib/fay/local/<pkg>/desc
```

### Build flow (on-device, with Zig or tcc installed)

```
fay install --build lua
  1. Download source tarball from upstream
  2. Verify SHA-256
  3. Extract to /var/tmp/fay/build/
  4. Apply patches in order
  5. Run build commands (fsh)
  6. Run package commands → files staged in $pkgdir
  7. Create .tar.gz from staged files
  8. Install as normal
```

## Compilation realms

Fornax has two userspace realms, and packages belong to one:

### Native realm (`realm: "native"`)

- Zig programs linked against `lib/fornax.zig`
- Direct access to Plan 9-style kernel syscalls
- No libc, no POSIX compatibility layer
- Examples: init, fsh, fxfs, all core utilities

### POSIX realm (`realm: "posix"`)

- C programs compiled against musl libc
- Linux syscalls translated to Fornax equivalents by `lib/posix/shim.c`
- Statically linked — no shared libraries
- Examples: lua, less, xxd, tcc

## Compiler strategy

Two-tier on-device compilation:

1. **tcc** — included in the base disk image (cross-compiled by Zig during `make`). Tiny C compiler (~100KB binary), self-hosting. Provides immediate C compilation capability for POSIX realm packages.

2. **Zig** — installed via `fay install build-essential`. Pre-built cross-compiled binary. Full Zig compiler + C toolchain (`zig cc`) for native realm packages and more complex C builds.

Most users only need pre-built packages (`fay install <pkg>`). The compilers are for building from source.

## Package format

Packages are gzipped tar archives containing files relative to `/`:

```
lua-5.4.7-1-x86_64.tar.gz
├── .PKGINFO              # metadata (JSON)
├── .INSTALL              # optional post-install fsh script
├── bin/
│   └── lua
└── share/
    └── lua/
        └── 5.4/
```

## Versioning

Arch Linux-style: `epoch:pkgver-pkgrel`

- **pkgver** — upstream version (e.g. `5.4.7`)
- **pkgrel** — package revision (bump for packaging changes)
- **epoch** — overrides version comparison (for upstream version scheme changes)

Comparison order: epoch → pkgver (segment-by-segment) → pkgrel.

## On-device directories

```
/var/lib/fay/local/         # installed package database
/var/lib/fay/local/<pkg>/
  desc                      # package metadata
  files                     # list of installed file paths
/var/lib/fay/sync/
  repo.json                 # cached package index
/var/cache/fay/             # downloaded tarballs
/var/tmp/fay/               # build working directory
/etc/fay.conf               # server URL configuration
```

## Network / HTTPS

`fay` uses the `lib/http.zig` HTTP client, which operates over Fornax's Plan 9 `/net/tcp/*` virtual filesystem.

**Development**: local HTTP server on the host (`python3 -m http.server 8000`), accessed from Fornax via QEMU's `10.0.2.2:8000`.

**Production**: HTTPS support will come after porting bearssl (~15K lines C, no deps) as an early `fay` package.

## Foundation libraries

`fay` depends on these libraries in `lib/`, all accessible via `@import("fornax")`:

| Library | Access | Purpose |
|---------|--------|---------|
| `lib/crc32.zig` | `fx.crc32` | CRC32 for gzip integrity |
| `lib/sha256.zig` | `fx.sha256` | Package checksum verification |
| `lib/deflate.zig` | `fx.deflate` | Gzip decompression |
| `lib/tar.zig` | `fx.tar` | Tar archive extraction |
| `lib/json.zig` | `fx.json` | Parse repo.json and FAYBUILD |
| `lib/http.zig` | `fx.http` | Download packages from server |

## fornax-ports repo

Package definitions live in a separate repo (`../fornax-ports/`). See its README for details on adding packages.

```
fornax-ports/
├── repo.json              # auto-generated package index
├── core/                  # base OS packages
├── extra/                 # additional packages
└── posix/                 # POSIX realm C packages
    └── xxd/
        ├── FAYBUILD       # package definition (JSON)
        └── xxd.c          # bundled source
```

Each package has a `FAYBUILD` file describing its metadata, dependencies, source locations, build steps, and install steps. `fay-build` reads these to cross-compile packages on the host and generate `repo.json`.

## Implementation status

| Phase | Description | Status |
|-------|-------------|--------|
| 1001a-d | Foundation libraries (crc32, sha256, deflate, tar, json, http) | Done |
| 1001l | fsh `for` loop | Done |
| 1001e | `fay` core (local install/remove/list) | Planned |
| 1001f | `fay sync` + remote fetch | Planned |
| 1001g | Dependency resolution | Planned |
| 1001h | `fay upgrade` + version comparison | Planned |
| 1001i | Cross-compile tcc for base image | Planned |
| 1001j | `fay-build` host tool | Planned |
| 1001k | `build-essential` (Zig for on-device) | Planned |
