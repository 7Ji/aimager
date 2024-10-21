echo -n "all:" > Makefile
printf ' test-%s' x86_64 aarch64 riscv64 loongarch64  >> Makefile
echo >> Makefile
for arch_prefix in \
	x86_64:x86_64-linux-gnu- \
	aarch64:aarch64-linux-gnu- \
	riscv64:riscv64-linux-gnu- \
	loongarch64:loongarch64-linux-gnu- \
;
do
	arch=${arch_prefix%%:*}
	prefix=${arch_prefix##*:}
	printf 'hello-%s: hello.c\n\t%sgcc -DARCH=\\"%s\\" -static -o $@ $^\n' "$arch" "$prefix" "$arch"
	printf 'test-%s: hello-%s\n\t[[ "$(shell ./hello-%s)" == "Hello from architecture: %s" ]]\n' "$arch" "$arch" "$arch" "$arch"
done >> Makefile
make
