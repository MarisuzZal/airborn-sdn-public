#!/usr/bin/env bash
# compile.sh
# Compile the PSA P4 program to an eBPF object (p4c-ebpf -> clang).
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/p4src/sdn_switch_psa.p4"
OUT="$HERE/build"
P4C_RUNTIME="$HOME/p4c/backends/ebpf/runtime"
mkdir -p "$OUT"

echo ">>> p4c-ebpf: P4 (PSA) -> C"
p4c-ebpf --arch psa --target kernel -o "$OUT/sdn_switch_psa.c" "$SRC"

echo ">>> clang: C -> eBPF object"
clang -O2 -g -target bpf -c \
  -I "$P4C_RUNTIME" \
  -I "$P4C_RUNTIME/contrib/libbpf/include/uapi" \
  -idirafter /usr/include \
  -idirafter /usr/include/x86_64-linux-gnu \
  "$OUT/sdn_switch_psa.c" -o "$OUT/sdn_switch_psa.o"

echo ">>> Done: $OUT/sdn_switch_psa.o"
