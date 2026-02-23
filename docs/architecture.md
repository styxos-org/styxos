---
date: 2026-02-20
title: Architecture
---


# StyxOS Architecture

> Nobody will ever need more than 64 Megabytes of RAM.

Recently, I wanted to invent the _HomeopathOS_, a satiric operating system that contains one productive line of code dilued by millions of bloatware code. I quickly realized that such systems already exist. So, why not get to the core and compile a Linux kernel, bundle it with a minimum of services to serve as a runtime for server application.

## Core Features

- **Minimal Kernel**: A lightweight Linux kernel tailored for server applications.
- **Efficient Services**: A minimal set of essential services optimized for performance.
- **Scalability**: Designed to scale efficiently from single-core systems to large clusters.

## Components

{{< image src="/img/arch.svg" title="Components of StyxOS" loading="lazy" >}}
