/// OCI/Docker image import tool for Fornax.
///
/// This is a userspace tool (not kernel) that:
///   1. Reads an OCI image manifest (JSON)
///   2. Unpacks layer tarballs
///   3. Applies layers in order (overlay semantics) → Fornax rootfs
///   4. Stores as a Fornax-native container image
///
/// For Milestone 4: starts with flat directory images.
/// Tar/overlay support comes later.
///
/// Usage: oci_import <image_path>
///
/// The tool reads the OCI image from the filesystem (via Fornax file syscalls)
/// and produces a Fornax-native container directory tree.
const fornax = @import("fornax");

/// OCI image manifest (simplified).
/// Full spec: https://github.com/opencontainers/image-spec
const OciManifest = struct {
    schema_version: u32,
    // In the real implementation, these would be parsed from JSON:
    // media_type: []const u8,
    // config: Descriptor,
    // layers: []Descriptor,
};

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\call _main
        \\ud2
    );
}

export fn _main() callconv(.c) noreturn {
    _ = fornax.write(1, "[oci_import] Fornax OCI Import Tool\n");
    _ = fornax.write(1, "[oci_import] Ready to import container images.\n");

    // TODO: For Milestone 4, the full implementation will:
    //
    // 1. open() the image manifest file
    // 2. read() and parse the JSON manifest
    // 3. For each layer:
    //    a. open() the layer tarball
    //    b. Parse tar headers, extract files
    //    c. Write extracted files to the rootfs directory
    // 4. Create container config from OCI config
    //
    // For now, this is a stub that proves the tool can run as a
    // userspace process in the Fornax process model.

    _ = fornax.write(1, "[oci_import] No image specified, exiting.\n");
    fornax.exit(0);
}
