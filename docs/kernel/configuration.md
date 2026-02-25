---
title: Configuration
weight: 1
---

# Configuration

The Linux kernel provides a vast of options that can be selected. Many of them are meant to provide a wide range of hardware support and software features. Configuring interactively with `make nconfig` will need a lot of time and research. 

For a minimal kernel, the best approach is to `make allnoconfig` to deactivate any option. This will probably result in a kernel booting right into a `kernel panic`, because essential drivers are missing.

Personally, I use a laptop with Fedora Silverblue compiling everything in a Toolbox container. This is my initial setup

```bash
toolbox create styxos
toolbox enter styxos

sudo dnf install gcc make flex bison elfutils-libelf-devel openssl-devel bc debootstrap qemu-system-x86 qemu-img ncurses-devel

mkdir -p styxos/kernel
cd styxos
git submodule add --depth 1 https://github.com/torvalds/linux src
git fetch origin tag v6.19 --depth 1
git checkout tags/v6.19
```

You can update your kernel version by just `git checkout` a more recent tag and recompile.


## Enabling Modules Step-by-Step 

I created the following list of options along try-and-error compiling and booting into a Qemu virtual machine. The resulting kernel is able to handle virtual network, block devices and the attached `/var` file system.

```bash
cd kernel/src
make allnoconfig

# Core & Exec
./scripts/config --enable 64BIT
./scripts/config --enable NAMESPACES
./scripts/config --enable CGROUPS
./scripts/config --enable PRINTK
./scripts/config --enable BLK_DEV_INITRD
./scripts/config --enable RD_GZIP
./scripts/config --enable BINFMT_ELF
./scripts/config --enable BINFMT_SCRIPT

# Driver Infrastructure
./scripts/config --enable TTY
./scripts/config --enable SERIAL_8250
./scripts/config --enable SERIAL_8250_CONSOLE
./scripts/config --enable DEVTMPFS
./scripts/config --enable DEVTMPFS_MOUNT

# Network Stack (Essential for TCP/IP and Sockets)
./scripts/config --enable NET
./scripts/config --enable INET
./scripts/config --enable UNIX
./scripts/config --enable PACKET

# Bus & Virtio for Qemu
./scripts/config --enable PCI
./scripts/config --enable PCI_MSI
./scripts/config --enable VIRTIO_MENU
./scripts/config --enable VIRTIO_PCI
./scripts/config --enable NETDEVICES
./scripts/config --enable ETHERNET
./scripts/config --enable VIRTIO_NET

# File system
./scripts/config --enable BLOCK
./scripts/config --enable BLK_DEV
./scripts/config --enable VIRTIO_BLK
./scripts/config --enable EXT4_FS

make olddefconfig
make -j$(nproc)
```
