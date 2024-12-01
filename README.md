# WORK IN PROGRESS, DO NOT USE!!!

## In-and-out

aimager is a **rootless**, **cross-distro** and **cross-architecture** Arch Linux and Arch Linux ports image/archive builder, with all of its logic written in **a single Bash script file** using only Bash-native logics and a limited set of Linux tools as dependencies, with config built-in.

aimager does not depend on any other Arch installation script (the common `pacstrap`, `genfstab`, etc), all it depends is `pacman`, and it knows how to fetch a statically built one that would run on any other distro (like on the Github Actions' Ubuntu runners) if it fails to find it on the current system.

With aimager, you can easily build e.g. an **Arch Linux ARM** image for aarch64 in a **Ubuntu x86_64** environment, an **Arch Linux RISC-V** image for riscv64 in an **Armbian aarch64** environment, etc. And, of cource, you can always build an **Arch Linux** image for x86_64 in an **Arch Linux x86_64** environment.

Some of the important factors about aimager are as follows:

### rootless

aimager utilizes [Linux user namespaces](https://www.man7.org/linux/man-pages/man7/user_namespaces.7.html) and [unshare.1](https://www.man7.org/linux/man-pages/man1/unshare.1.html) to create a user namespace, unshare mount, pid, etc from host, then map the current user running child Bash instance running the script to the root account in child namespace. The mapped root account has limited capability of doing selected (types and sets of) mounts and a partial root tree is constructed in the child mount namespace.

In this child user namespace **pacman** from the host architecture would be called, either provided by system (when pacman can be found in `PATH`, like on Arch and Arch ports) or downloaded lazily from archlinuxcn repo's pacman-static package (when pacman cannot be found in `PATH`, like on non-Arch systems, or when user explicitly request to use this method), and a pacman config earlier prepared by aimager would be provided to this pacman instance, either loose (skipping package signature verifying, used when initializing the keyring for the first time) or strict (requiring package signature verifying, used in other cases).

Whether loose or strict, the pacman configs are both created dynamically from the target image core repo's pacman config (unless user has requested against such behaviour) with some simple text parsing to extract the pre-defined repo names, however all other configs are specially prepared by aimager so the host pacman knows it is running in the host root and target paths point into the target chroot, and the config has pre-defined architecture so it knows the target architecture to use. It is the pacman itself that does chroot.

The host pacman does chroot by itself to prepare the target installation just like when using pacstrap, but the target hooks run inside the target mount namespace and are actually run by qemu-static binfmt when cross-building and are almost like really running in the target architecture.

An interesting point to mark here is that, not only are only host pacman and host pacman configs used, they also do not affect the target pacman and pacman config to install. That is, target pacman has its binary and configs installed by host pacman just like any other packages, it's not touched at all because it does not need to be touched for our cross-installation logic to work.

### cross-distro

aimager by its nature does not care about the host environment, the only hard dependency about Arch in aimager is `pacman` and it knows how to get a statically built one from Internet for aarch64 and x86_64 currently. Running aimager on Arch and on Debian, Fedora, etc are almost the same, except whether `pacman` is already provided by system or downloaded by aimager itself.

The biggest reason we do not depend on `pacstrap` is that we need manual hack to use it for cross-distro build anyway: `pacstrap` relies heavily on the host pacman configuration if not given a custom config and when given a custom config it still misses a point I want: the configuration paths always start from target root, and it cannot re-use caches on host as a result without more bind-mount hacks. It has many assumptions about the host tool versions and behaviours and are not always met when running on a non-Arch environment. It is also not always provided by the host system, and the version just cannot be guaranteed even when it's provided. Considering all of the headaches if we assume a `pacstrap` dependency, I'd rather re-do those logics natively in a more distro-insensitive way as I can and drop `pacstrap` altogether.

In many cases cross-distro is a bad thing as one would need to guarantee too many things about the target environment other might run the program on. So aimager has a strict enough dependencies detection logic and try to bring as few external dependencies as possible. Every executable called in Bash, if allowed, would be replaced by a Bash-native logic when possible.

The biggest driving point for this, of course, is that I want to make aimager runnable on a free Github Actions runner so I can have free CPU power to build for boards I have.

### cross-architecture

Thanks to qemu-static-binfmt, if one has that configured, ELFs from other architecture can be simply run on the currently system almost like when it runs on the target architecture natively, except the performance penalties.

However as the installation has some key processes that are CPU-intensive, aimager still has to make some workarounds to avoid running those via QEMU. These includes that pacman is always run on host natively and keyrings are backed up and restored when possible.

All keyring packages are installed in the boostrap stage together with the base group, and then a keyring-id is formatted using all package names. If a previously initialized and populated keyring backup archive with that id is found then it is simply reused, and in this case the boostrap in done with a strict pacman config so all packages are verified. It is only when a keyring backup is not found would aimager do `pacman-key --init` and `pacman-key --populate` in the target chroot, and even when that's the case, aimager can re-use a previously created native-arch root archive to "borrow" the gpg and its dependencies to the CPU-intensive encryption and decryption would be performed on the host natively (with `--keyring-helper` option).

### single-file

aimager is not only single-file, it also forbids the use of `source` and `.`. It assumes no file/folder under the current work directory. This makes it elegant to simply run aiamger from a differnt path.

Also aimager is written with config-as-code mindset. That is, it would not read a config file like the builders you've seen a lot. It instead has already distros, boards, third-party repos built-in and you use simple `--distro`, `--board`, etc to call the built-in definition functions. One should hack aimager the script itself if they want to add support for more distros and boards, and they use simply the Bash syntax and can re-use everything that's already available in aimager's context.

To be more precise, aimager has a hidden, second script that the main aimager script would spawn: the `child.sh` script, which is always generated as `cache/build.[build id]/bin/child.sh`, containing all variable and function definitions in aimager itself and run only the `child()` function.

It is always posisble to convert aimager to a multi-file layout, like spilitting it into a lib and a wrapper. But for now, this is my personal choice, and it's also my opinion that aimager should not be used as a library.

<!-- - -->


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