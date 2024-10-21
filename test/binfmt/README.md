# binfmt testing

This tests whether binfmt was configured correctly.

It also needs the corresponding Arch cross toolchain so testing executables could be compiled on-the-fly. Prebuilt binary would not be shipped due to the concern that blobs in public repo could potentially result in backdoor (reference XZ Utils backdoor for example). You're of course free to include them if you want to do that in your forked projects.

## Aarchitecture

Currently all of the supported architectures are: `x86_64`, `aarch64`, `riscv64` and `loongarch64`. For each of the target, if it's not the native architecture, then all of `[architecture]-linux-gnu-gcc`, `[architecture]-linux-gnu-binutils`, `[architecture]-linux-gnu-glibc` and `qemu-user-static-binfmt` are needed. For example, if you want to test for riscv64, then these are needed:
- `riscv64-linux-gnu-gcc`: to compile `hello.c` to `hello-riscv64`
- `riscv64-linux-gnu-binutils`: to link `hello-riscv64` and run it
- `riscv64-linux-gnu-glibc`: to be linked with
- `qemu-user-static-binfmt`: to run `/usr/riscv64-linux-gnu/lib/ld-linux-riscv64-lp64d.so.1`

To test for `riscv64`, run `./test.sh` first to generate Makefile, then run the corresponding make target
```sh
./test.sh # This would run all test targets, you can interrupt it
make test-riscv64
```

## Test-them-all

In the current working directory, just run `./test.sh` to generate Makefile. After it's generated, you can just run `make` to do all tests
```sh
./test.sh
make
```