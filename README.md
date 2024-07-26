# aimager (ArchLinux Imager)

A rootless distro-independent and architecture-independent Arch Linux and Arch-derive image builder


## Design principals

- Rootless
  - The builder always run rootless, thanks to user namespaces, it needs no root access or fakeroot. 
  - There is no plan to introduce rootful packing, as that's already done by a lot of image builders
- Distro-independent
  - The builder runs on Arch and Arch-derive (of course) and also runs on non-Arch systems, like on Debian-derive. The main target is Ubuntu 22.04 that Github Actions uses.
- Architecture-independent
  - The builder should do cross-architecture boostrapping effortlessly.
- No leftovers
  - The builder does nothing to your user config or system config, expect no toolchain leftovers or environment modifications you saw in other image packers
- Bash only
  - Do every possible operations in C, only spawn a Shell when we definitely need to
- Single script
  - All logic in a single 

## Limitations

Most of the limitations come from the fact that the builder runs rootlessly
- No btrfs subvolumes
  - As we run rootlessly we can only use `mkfs.btrfs -r/--rootdir` to pre-populate a btrfs partition
- No 