# WORK IN PROGRESS, DO NOT USE!!!

<!-- This is commented out.
# aimager (ArchLinux Imager)
A rootless distro-independent and architecture-independent Arch Linux and Arch-derive image builder

## Design principals

These are what I insisted when writing aimager and I hope future contributors follow: 

- **Single File**: Both the builder logic and distro and architecture configurations are contained in a single Bash shell script file. There is no external config. This makes it easy to carry both the builder and the config around.
- **Code As Configuration**: No domain-specific configuration format. Configuration is done by either supplying command-line arguments or embedding into the builder script itself, which then always follow the Bash syntax and can utilize Bash-native helper logics.
- **Rootless**: The builder runs without root permission and utilizes user namespace to emulate a full UID/GID space to do installation. This is no rootful mounting, no host installation, no modification to root. Even if the builder breaks there wouldn't be mounting leftovers on host.
- **Distribution Independent**: Does not really care about both the host and target distribution. These even applies when the host distribution is not any Arch-derived. Specifically this makes the builder usable in a Ubuntu environment, which is what Github Action uses.
- **Self-Contained Depdency**: If there's any dependency that needs to be prepared, other than those standard Linux utilities, the builder could and would fetch and prepare them by itself. Most notably it would prepare `pacman-static` for a non-Arch environment and you don't need to worry about preparing all its dependencies.

## Support matrix

Only Arch and Arch ports would be listed here, arch-derives are too many and I'll just omit them. For distros that supports multiple architectures only the latest one is listed (E.g. Arch Linux 32 supports i486, pentium4 and i686, only i686 is listed here).

target v \ host ->|Arch Linux (x86_64)|Arch Linux 32 (i686)|Arch Linux ARM (aarch64)|Loong Arch Linux (loongarch64)|Arch Linux RISC-V (riscv64)
-|-|-|-|-|-
Arch Linux (x86_64)|tested
Arch Linux 32 (i686)|tested
Arch Linux ARM (aarch64)|tested
Loong Arch Linux (loongarch64)|tested
Arch Linux RISC-V (riscv64)|tested

## Limitations

Most of the limitations come from the fact that the builder runs rootlessly
- No btrfs subvolumes
  - As we run rootlessly we can only use `mkfs.btrfs -r/--rootdir` to pre-populate a btrfs partition
- No 
<-->