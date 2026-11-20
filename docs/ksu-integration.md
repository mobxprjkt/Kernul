# KSU integration notes

This build tree supports two independent root variants:

- `ksun`: KernelSU-Next using the SUSFS-enabled `pershoot/KernelSU-Next` `dev-susfs` setup branch.
- `suki`: SukiSU-Ultra using its `main` integration branch (kprobe-based integration), plus the Android 13 / 5.15 SUSFS patch set.
- `none`: no KSU driver is installed.

The SukiSU `builtin` branch is intentionally not used by this workflow. That branch requires manual hook calls to be added to the kernel source, and those hook sites/signatures must be maintained against the exact kernel tree. Using `main` avoids silently producing a kernel with an unintegrated builtin branch.

## SUSFS behavior

The setup step now fails if the selected SUSFS repository/branch or patch is unavailable, or if the patch conflicts. It also detects an already-applied patch. This is deliberate: a partially integrated SUSFS kernel must not continue to compilation as if setup succeeded.

The patch set is specifically `gki-android13-5.15`. Do not use it for another kernel base without selecting the matching SUSFS branch and patch series. The setup script records the exact SUSFS commit in the workflow environment.

## Required checks

Before building, verify:

- The source tree is a Linux kernel root with `drivers/Makefile` and `drivers/Kconfig`.
- The defconfig enables `CONFIG_KSU=y` for either KSU variant.
- SukiSU `main` has `CONFIG_KPROBES=y` and `CONFIG_EXT4_FS=y` available; Kconfig handles its remaining dependencies.
- `CONFIG_KPM=y` is enabled only for the SukiSU variant when the KPM patch step is used.
- The KSU manager APK matches the KSU kernel version code.

The repository archive does not contain the target kernel source, so patch-context compatibility and a full kernel compile must be verified in the actual kernel checkout / CI run.
