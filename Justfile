KERNEL_DIR := "kernel/src"
KERNEL_VERSION := "6.19"

# Install Container runtime (crun)
insruntime:
    -mkdir -p overlay/usr/bin
    wget -nc -O overlay/usr/bin/crun https://github.com/containers/crun/releases/download/1.26/crun-1.26-linux-amd64
    chmod +x overlay/usr/bin/crun

# Make customized RAM file system (initramfs)
initramfs:
    -rm -rf rootfs
    mkdir rootfs
    mkdir -p rootfs/{proc,sys,dev,var,bin,sbin,etc,tmp,usr/bin,usr/sbin}

    # Install Core Components
    cp core/init/zig-out/bin/init rootfs/init
    cp core/zish/zig-out/bin/zish rootfs/bin/zish
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
