#!/usr/bin/env bash
# prepare_node.sh
# Per-node bring-up on Raspberry Pi (Ubuntu Server 24.04 ARM64): toolchain and NIKSS build.
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

set -euo pipefail

CODENAME="$(. /etc/os-release; echo "${VERSION_CODENAME:-noble}")"

echo ">>> [0/3] Ensure the ${CODENAME}-updates suite exists (often missing on a fresh Server)"
if ! grep -rhq "${CODENAME}-updates" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
  echo "deb http://ports.ubuntu.com/ubuntu-ports ${CODENAME}-updates main restricted universe multiverse" \
    | sudo tee /etc/apt/sources.list.d/${CODENAME}-updates.list
fi

echo ">>> [1/3] Packages (noninteractive - no iperf3 daemon prompt)"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git make cmake gcc clang llvm \
  libgmp-dev libelf-dev zlib1g-dev libjansson-dev libpcap-dev libbpf-dev \
  iproute2 ethtool tcpdump iperf3 python3 openssh-server

echo ">>> [2/3] Building NIKSS from source"
if [ ! -d "$HOME/nikss" ]; then
  git clone --recursive https://github.com/NIKSS-vSwitch/nikss.git "$HOME/nikss"
fi
cd "$HOME/nikss" && ./build_libbpf.sh
mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release .. && make -j"$(nproc)" && sudo make install && sudo ldconfig

echo ">>> [3/3] Verification"
which nikss-ctl
sudo nikss-ctl validate-os
echo
echo "Done. Copy sdn_switch_psa.o and load it:"
echo "  sudo nikss-ctl pipeline load id 1 ~/sdn_switch_psa.o"
