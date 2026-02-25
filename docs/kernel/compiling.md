---
title: Compiling
---

# Compiling

This is a condensed, step-by-step version of the guide, optimized for experienced users. For in-depth explanations, refer to the [official kernel documentation](https://www.kernel.org/doc/html/latest/admin-guide/README.html).

### 1. Install Build Dependencies

Ensure your toolchain is ready. On Fedora, use `dnf` or a toolbox/distrobox container:

```bash
# Example for Debian/Ubuntu-based containers
sudo apt install build-essential libncurses-dev bison flex libssl-dev libelf-dev
```

### 2. Download and Extract Source

Get the desired version from [kernel.org](https://www.kernel.org/):

```bash
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.x.y.tar.xz
tar -xvf linux-6.x.y.tar.xz && cd linux-6.x.y
```

### 3. Configuration

Use your existing system config as a baseline or start fresh:

* **Existing config:** `cp /boot/config-$(uname -r) .config` followed by `make oldconfig`
* **Default:** `make defconfig`
* **Interactive (UI):** `make menuconfig`

### 4. Compilation

Build the kernel image and modules using all available cores:

```bash
make -j$(nproc)
```

This produces the `bzImage` file.

{{% hint info %}}
**Just in Case**
In this project, the configuration and compilation is handled by the `Justfile` in the project directory.
{{% /hint %}}

### Essential Tips

* **Cleanup:** Use `make clean` to remove build files but keep your `.config`. Use `make mrproper` to reset the tree entirely.
* **Safety:** Never delete your previous working kernel until the new one is confirmed stable.
* **Localmodconfig:** Run `make localmodconfig` to disable all modules not currently loaded by your system for a much faster build.

Would you like me to create a `Justfile` to automate these steps for your local environment?
