"""StyxOS build pipeline as Dagger Functions.

Mirrors the top-level Justfile targets, but runs every step inside a Linux
container so the kernel and the static musl userland build reproducibly on any
host (including macOS).

Bootstrap once:

    dagger develop

Then, e.g.:

    dagger call all       export --path=build     # bzImage + initramfs.cpio.gz
    dagger call core      export --path=build/core
    dagger call kernel    export --path=build/bzImage
    dagger call initramfs export --path=build/initramfs.cpio.gz
"""

from typing import Annotated

import dagger
from dagger import DefaultPath, dag, function, object_type

ZIG_VERSION = "0.15.2"
BUSYBOX_VERSION = "1.36.1"
ALPINE = "alpine:3.20"
DEBIAN = "debian:stable-slim"
RUST = "rust:1-alpine"


@object_type
class Styxos:
    # The whole repository, auto-filled with the module root when called via
    # `dagger call ...`. Override with `--source` if needed.
    source: Annotated[dagger.Directory, DefaultPath("/")]

    # ----------------------------------------------------------------- Zig ---
    def _zig_base(self) -> dagger.Container:
        """Alpine (musl) + pinned Zig toolchain + libs for the sqlite-linkers."""
        arch_dir = f"zig-linux-x86_64-{ZIG_VERSION}"
        url = f"https://ziglang.org/download/{ZIG_VERSION}/{arch_dir}.tar.xz"
        return (
            dag.container()
            .from_(ALPINE)
            .with_exec(
                [
                    "apk", "add", "--no-cache",
                    "curl", "xz", "build-base",
                    # charon and pluto link the system sqlite3 statically:
                    "sqlite-dev", "sqlite-static",
                ]
            )
            .with_exec(["sh", "-c", f"curl -fsSL {url} | tar -xJ -C /opt"])
            .with_env_variable("PATH", f"/opt/{arch_dir}:${{PATH}}", expand=True)
            .with_env_variable("ZIG_GLOBAL_CACHE_DIR", "/zig-global-cache")
            .with_mounted_cache(
                "/zig-global-cache", dag.cache_volume("styxos-zig-global")
            )
        )

    def _zig_project(self, name: str) -> dagger.Container:
        """A Zig base with `core/<name>` mounted and a per-project build cache."""
        return (
            self._zig_base()
            .with_directory(f"/src/{name}", self.source.directory(f"core/{name}"))
            .with_workdir(f"/src/{name}")
            .with_mounted_cache(
                f"/src/{name}/.zig-cache",
                dag.cache_volume(f"styxos-zig-{name}"),
            )
        )

    def _zig_bin(self, name: str, out: str, extra: list[str]) -> dagger.File:
        return (
            self._zig_project(name)
            .with_exec(["zig", "build", "-Doptimize=ReleaseSmall", *extra])
            .file(f"/src/{name}/zig-out/bin/{out}")
        )

    @function
    def init(self) -> dagger.File:
        """PID 1. Target (x86_64-linux-musl static) is hardcoded in build.zig."""
        return self._zig_bin("init", "init", ["-Dinteractive=false"])

    @function
    def zish(self) -> dagger.File:
        """The zish shell, built as a static musl binary."""
        return self._zig_bin("zish", "zish", ["-Dtarget=x86_64-linux-musl"])

    @function
    def lz(self) -> dagger.File:
        """The lz packer, built as a static musl binary."""
        return self._zig_bin("lz", "lz", ["-Dtarget=x86_64-linux-musl"])

    @function
    def pluto(self) -> dagger.File:
        """pluto (links the system sqlite3; native musl in the Alpine base)."""
        return self._zig_bin("pluto", "pluto", [])

    @function
    def charon(self) -> dagger.Directory:
        """charon + charonctl (links the system sqlite3)."""
        return (
            self._zig_project("charon")
            .with_exec(["zig", "build", "-Doptimize=ReleaseSmall"])
            .directory("/src/charon/zig-out/bin")
        )

    # --------------------------------------------------------------- Rust ---
    @function
    def stylo(self) -> dagger.File:
        """stylo (Rust, release). rusqlite `bundled` compiles sqlite from source."""
        return (
            dag.container()
            .from_(RUST)
            .with_exec(["apk", "add", "--no-cache", "musl-dev", "gcc", "make"])
            .with_mounted_cache(
                "/usr/local/cargo/registry",
                dag.cache_volume("styxos-cargo-registry"),
            )
            .with_directory("/src", self.source.directory("core/stylo"))
            .with_workdir("/src")
            .with_exec(["cargo", "build", "--release"])
            .file("/src/target/release/stylo")
        )

    # ------------------------------------------------------------ busybox ---
    @function
    def busybox(self) -> dagger.File:
        """Static musl busybox from the checked-in config."""
        src_dir = f"busybox-{BUSYBOX_VERSION}"
        tarball = f"{src_dir}.tar.bz2"
        return (
            dag.container()
            .from_(ALPINE)
            .with_exec(
                [
                    "apk", "add", "--no-cache",
                    "curl", "tar", "bzip2", "make", "gcc",
                    "musl-dev", "perl", "linux-headers",
                ]
            )
            .with_directory("/bb", self.source.directory("core/busybox"))
            .with_workdir("/bb")
            .with_exec(
                ["sh", "-c", f"curl -fsSLO https://busybox.net/downloads/{tarball}"]
            )
            .with_exec(["tar", "-xf", tarball])
            .with_exec(["cp", "config", f"{src_dir}/.config"])
            .with_workdir(f"/bb/{src_dir}")
            .with_exec(
                [
                    "sh", "-c",
                    "make CC=gcc LDFLAGS=-static "
                    "EXTRA_CFLAGS='-idirafter /usr/include' -j$(nproc)",
                ]
            )
            .file(f"/bb/{src_dir}/busybox")
        )

    # -------------------------------------------------------- aggregates ---
    @function
    def core(self) -> dagger.Directory:
        """Build every userland project; returns a tree of binaries."""
        return (
            dag.directory()
            .with_file("init", self.init())
            .with_file("bin/zish", self.zish())
            .with_file("bin/lz", self.lz())
            .with_file("bin/busybox", self.busybox())
            .with_file("bin/pluto", self.pluto())
            .with_file("bin/stylo", self.stylo())
            .with_directory("bin", self.charon())
        )

    @function
    def kernel(self) -> dagger.File:
        """Compile the configured Linux kernel and return the bzImage."""
        return (
            dag.container()
            .from_(DEBIAN)
            .with_exec(
                [
                    "sh", "-c",
                    "apt-get update && apt-get install -y --no-install-recommends "
                    "build-essential bison flex libelf-dev libssl-dev bc kmod "
                    "cpio xz-utils",
                ]
            )
            .with_directory("/styxos", self.source)
            .with_workdir("/styxos/kernel/src")
            .with_exec(["cp", "../styxos-kernel.cfg", ".config"])
            .with_exec(["make", "olddefconfig"])
            .with_exec(["sh", "-c", "make -j$(nproc) bzImage"])
            .file("/styxos/kernel/src/arch/x86/boot/bzImage")
        )

    @function
    def initramfs(self) -> dagger.File:
        """Assemble rootfs (init, zish, busybox + symlinks, overlay) into a cpio.gz."""
        dirs = [
            "proc", "sys", "dev", "var", "bin", "sbin",
            "etc", "tmp", "usr/bin", "usr/sbin",
        ]
        mkdirs = " ".join(f"/rootfs/{d}" for d in dirs)
        return (
            dag.container()
            .from_(ALPINE)
            .with_exec(["apk", "add", "--no-cache", "cpio", "gzip", "findutils"])
            .with_exec(["sh", "-c", f"mkdir -p {mkdirs}"])
            # Base overlay (etc/inittab, os-release, udhcpc scripts, ...)
            .with_directory("/overlay", self.source.directory("overlay"))
            .with_exec(["sh", "-c", "cp -a /overlay/. /rootfs/"])
            # Core components
            .with_file("/rootfs/init", self.init(), permissions=0o755)
            .with_file("/rootfs/bin/zish", self.zish(), permissions=0o755)
            .with_file("/rootfs/bin/busybox", self.busybox(), permissions=0o755)
            # Busybox applet symlinks
            .with_exec(
                [
                    "sh", "-c",
                    'for app in $(/rootfs/bin/busybox --list-full); do '
                    'mkdir -p "/rootfs/$(dirname "$app")"; '
                    'ln -sf /bin/busybox "/rootfs/$app"; done',
                ]
            )
            # Pack
            .with_exec(
                [
                    "sh", "-c",
                    "cd /rootfs && find . -print0 | "
                    "cpio --null -ov -H newc --owner=root:root | "
                    "gzip -9 > /initramfs.cpio.gz",
                ]
            )
            .file("/initramfs.cpio.gz")
        )

    @function
    def all(self) -> dagger.Directory:
        """Everything the `just all` target produces: bzImage + initramfs."""
        return (
            dag.directory()
            .with_file("bzImage", self.kernel())
            .with_file("initramfs.cpio.gz", self.initramfs())
        )

    @function
    async def check(self) -> str:
        """Compile-check the lethe library (it ships no binary)."""
        return await (
            self._zig_project("lethe")
            .with_exec(["zig", "build"])
            .stdout()
        )
