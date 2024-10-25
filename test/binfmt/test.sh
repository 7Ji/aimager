#!/bin/bash -e
echo -n "all:" > Makefile
printf ' test-%s' x86_64 aarch64 riscv64 loongarch64  >> Makefile
echo >> Makefile
for arch in \
	x86_64 \
	aarch64 \
	riscv64 \
	loongarch64 \
;
do
	triplet="${arch}-linux-gnu"
	printf 'hello-%s: hello.c\n\t%s-gcc -DARCH=\\"%s\\" -o $@ $^\n' "$arch" "$triplet" "$arch"
	if  [[ "$arch" == $(uname -m) ]]; then
		printf 'test-%s: hello-%s\n\t[[ "$(shell ./hello-%s)" == "Hello from architecture: %s" ]]\n' "$arch" "$arch" "$arch" "$arch"
	else
		printf 'test-%s: hello-%s\n\t[[ "$(shell /usr/%s/lib/ld-linux-*.so.* --library-path /usr/%s/lib ./hello-%s)" == "Hello from architecture: %s" ]]\n' "$arch" "$arch" "$triplet" "$triplet" "$arch" "$arch"
	fi
	printf '\trm -f hello-%s\n' "$arch"
done >> Makefile
if [[ "$1" ]]; then
	make test-"$1"
else
	make
fi
rm -f Makefile hello-*
