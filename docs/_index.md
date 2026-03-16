---
title: "The StyxOS Documentation"
weight: 1
---


# StyxOS Documentation

{{< badge style="success" title="Build" value="Passing" >}}


## Getting Started

{{% steps %}}
1. ## Clone the Repository

   Clone the StyxOS repository to your local machine:
   ```bash
   git clone https://github.com/styxos-org/styxos
   cd styxos
   ```

2. ## Compile the Kernel

   Build the default StyxOS kernel by running:
   ```bash
   just kernel
   ```

   This configures the kernel source and outputs a `bzImage` file into the `build` directory.

3. ## Compile the Core Components

   Navigate to the `core` directory to build the essential system components.
   *Note: This requires [Zig](https://ziglang.org) v0.15.2 or newer.*

    ```bash
    cd core
    just build
    cd ..
    ```

    You need at least `core/init` successfully compiled to get a bootable system.

4. ## Build the System Image

    With the core components in place, pack everything into the [Initial RAM disk](https://en.wikipedia.org/wiki/Booting_process_of_Linux) (initramfs). Additional user-space tools are provided by BusyBox:

    ```bash
    just initramfs
    ```

5. ## Boot the System

   Start the final OS in your console using QEMU:
   ```bash
   just run
    ```
    
    **Experimental:** You can also run the system using [kvmtool](https://github.com/kvmtool/kvmtool), a lightweight, single-binary alternative that uses the kernel's KVM features directly:

    ```bash
    just runkvm
    ```
{{% /steps %}}

{{< button href="https://github.com/styxos-org" >}}Contribute{{< /button >}}
