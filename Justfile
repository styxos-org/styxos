KERNEL_DIR := "kernel/src"
KERNEL_VERSION := "6.19"
ALPINE_VERSION := "3.21.2"

# Install Container runtime (crun)
insruntime:
    -mkdir -p overlay/usr/bin
    wget -nc -O overlay/usr/bin/crun https://github.com/containers/crun/releases/download/1.26/crun-1.26-linux-amd64
    chmod +x overlay/usr/bin/crun

# Make customized RAM file system (initramfs)
initramfs:
    -mkdir -p build fs
    wget -nc -P build/ https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/alpine-minirootfs-{{ ALPINE_VERSION }}-x86_64.tar.gz || true

    # Completely empty fs/ for clean, reproducible builds
    -rm -rf fs/* fs/.[!.]*
    tar xf build/alpine-minirootfs-{{ ALPINE_VERSION }}-x86_64.tar.gz -C fs/
    -rm -rf fs/opt fs/mnt fs/usr/local fs/media

    # Force the init symlink
    ln -sf sbin/init fs/init

    # Apply the StyxOS overlay
    cp -a overlay/* fs/

    # Pack the archive enforcing root ownership
    cd fs && find . -print0 | cpio --null -ov -H newc --owner=root:root | gzip -9 > ../build/initramfs.cpio.gz

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
run:
    qemu-system-x86_64 \
        -kernel build/bzImage \
        -initrd build/initramfs.cpio.gz \
        -m 640 \
        -nographic \
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0 \
        -drive file=var.img,format=raw,if=virtio \
        -append "console=ttyS0 quiet rdinit=/init"
