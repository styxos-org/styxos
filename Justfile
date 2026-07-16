KERNEL_DIR := "kernel/src"
KERNEL_VERSION := "6.19"

# Userland projects under core/, each shipping its own Justfile with a `build` recipe
CORE_PROJECTS := "init zish lz busybox charon lethe pluto stylo"

# Build everything: kernel, core userland and the initramfs image
all: builddir kernel core initramfs

# Build all userland projects in core/ (delegates to each project's Justfile)
core:
    for p in {{CORE_PROJECTS}}; do \
        echo "==> building core/$p"; \
        just --justfile "core/$p/Justfile" --working-directory "core/$p" build || exit 1; \
    done

# Ensure the build output directory exists
[private]
builddir:
    mkdir -p build

# Install Container runtime (crun)
insruntime:
    -mkdir -p overlay/usr/bin
    wget -nc -O overlay/usr/bin/crun https://github.com/containers/crun/releases/download/1.26/crun-1.26-linux-amd64
    chmod +x overlay/usr/bin/crun

kvmtool:
    cd vendor/kvmtool && \
    make LDFLAGS="-static" \
         EXTRA_CFLAGS="-Wno-error -Wno-redundant-decls" \
         WERROR=0 \
         -j$(nproc)

# Make customized RAM file system (initramfs)
initramfs:
    -rm -rf rootfs
    mkdir rootfs
    mkdir -p rootfs/{proc,sys,dev,var,bin,sbin,etc,tmp,usr/bin,usr/sbin}

    # Install Core Components
    cp core/init/zig-out/bin/init rootfs/init
    cp core/zish/zig-out/bin/zish rootfs/bin/zish
    # cp vendor/lkvm/lkvm rootfs/bin/lkvm
    cp -a overlay/* rootfs/

    # Install Busybox and create symlinks
    cp core/busybox/build/busybox*/busybox rootfs/bin/
    for app in $(rootfs/bin/busybox --list-full); do \
        mkdir -p "rootfs/$(dirname $app)"; \
        ln -sf /bin/busybox "rootfs/$app"; \
    done

    # Compress initramfs
    cd rootfs && find . -print0 | cpio --null -ov -H newc --owner=root:root | gzip -9 > ../build/initramfs.cpio.gz
    cd -

# Compile the configured kernel
kernel:
    cp kernel/styxos-kernel.cfg kernel/src/.config
    cd kernel/src && make olddefconfig
    cd kernel/src && make -j$(nproc) bzImage
    cp kernel/src/arch/x86/boot/bzImage build

# Create disk image for /var mount
mkvar:
    mkdir -p build/var_skel
    cp -a fs/var/* build/var_skel/ 2>/dev/null || true
    mkdir -p build/var_skel/log
    mkdir -p build/var_skel/lib/containers

    truncate -s 1G var.img
    # More flexible:
    #qemu-img create -f raw var.img 1G
    mkfs.ext4 -d build/var_skel var.img
    rm -rf build/var_skel

# Run compiled kernel in QEMU
run: initramfs
    qemu-system-x86_64 \
        -kernel build/bzImage \
        -initrd build/initramfs.cpio.gz \
        -m 640 \
        -nographic \
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0 \
        -drive file=var.img,format=raw,if=virtio \
        -append "console=ttyS0 quiet rdinit=/init"

# Run compiled kernel in lkvm
runkvm:
    sudo ip tuntap add dev styxtap0 mode tap user $USER
    sudo ip addr add 10.0.0.1/24 dev styxtap0
    sudo ip link set styxtap0 up

    vendor/kvmtool/lkvm run \
        -m 512 \
        -c 2 \
        -k build/bzImage \
        -i build/initramfs.cpio.gz \
        --console serial \
        -n mode=tap,tapif=styxtap0,vhost=1 \
        -p "console=ttyS0 init=/bin/init"
