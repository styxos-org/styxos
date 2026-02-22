KERNEL_DIR := "kernel/src"
KERNEL_VERSION := "6.8"
CONFIG_SRC := "arch/x86/configs/styx_defconfig" # Pfad zu deiner gespeicherten Config anpassen
IMAGE := "styxos.qcow2"
MNT := "fs"
NBD := "/dev/nbd0"
ALPINE_URL := "https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz"
PWD := `pwd`

default:
    @just --list

# Upgrade kernel. Adjust KERNEL_VERSION in the Justfile.
upgrade-kernel:
    cd {{KERNEL_DIR}} && git fetch origin tag v{{KERNEL_VERSION}} --depth 1
    cd {{KERNEL_DIR}} && git checkout v{{KERNEL_VERSION}}
    cp {{CONFIG_SRC}} {{KERNEL_DIR}}/.config
    make -C {{KERNEL_DIR}} olddefconfig

# Initialize Submodule.
sync:
    git submodule update --init --depth 1 {{KERNEL_DIR}}

# Configure and build kernel.
build:
    cp {{CONFIG_SRC}} {{KERNEL_DIR}}/.config
    make -C {{KERNEL_DIR}} olddefconfig
    make -C {{KERNEL_DIR}} -j$(nproc) bzImage modules

# Build and mount image.
mount:
    qemu-img create -f qcow2 {{IMAGE}} 10G
    sudo modprobe nbd max_part=8
    sudo qemu-nbd -c {{NBD}} {{IMAGE}}
    sudo parted -s {{NBD}} mklabel msdos mkpart primary ext4 1MiB 100%
    sudo mkfs.ext4 {{NBD}}p1
    mkdir -p {{MNT}}
    sudo mount {{NBD}}p1 {{MNT}}

# Get root FS and install modules.
bootstrap:
    wget -qO alpine.tar.gz {{ALPINE_URL}}
    sudo tar xzf alpine.tar.gz -C {{MNT}}
    # Absolute Pfade für INSTALL_MOD_PATH nutzen, da make -C das Arbeitsverzeichnis ändert
    sudo make -C {{KERNEL_DIR}} INSTALL_MOD_PATH={{PWD}}/{{MNT}} modules_install
    rm alpine.tar.gz

# Chroot-Setup, Auto-Login and cleanup
setup:
    sudo cp /etc/resolv.conf {{MNT}}/etc/resolv.conf
    sudo chroot {{MNT}} apk update
    sudo chroot {{MNT}} apk add openrc
    
    echo "ttyS0::respawn:/bin/login -f root" | sudo tee -a {{MNT}}/etc/inittab > /dev/null
    
    sudo chroot {{MNT}} rc-update add devfs sysinit
    sudo chroot {{MNT}} rc-update add dmesg sysinit
    
    sudo rm -rf {{MNT}}/sbin/apk {{MNT}}/lib/apk {{MNT}}/etc/apk {{MNT}}/var/cache/apk {{MNT}}/var/lib/apk
    sudo rm -rf {{MNT}}/mnt {{MNT}}/media {{MNT}}/opt {{MNT}}/usr/local

# Unmount image.
umount:
    sudo umount {{MNT}} || true
    sudo qemu-nbd -d {{NBD}} || true

# start VM in headless mode.
run:
    qemu-system-x86_64 \
        -machine pc -accel kvm -m 2048 \
        -drive file={{IMAGE}},format=qcow2,if=virtio \
        -kernel {{KERNEL_DIR}}/arch/x86/boot/bzImage \
        -append "root=/dev/vda1 rw console=ttyS0" \
        -nographic
