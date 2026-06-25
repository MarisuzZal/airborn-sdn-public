#!/usr/bin/env bash
# provision_ebpf.sh
# Provision the eBPF/NIKSS toolchain inside the development VM.
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

set -euo pipefail

echo ">>> [1/5] System dependencies"
sudo apt-get update -y
sudo apt-get install -y \
  git make cmake gcc clang llvm \
  libgmp-dev libelf-dev zlib1g-dev libjansson-dev libpcap-dev libbpf-dev \
  linux-tools-common linux-tools-generic linux-headers-generic gcc-multilib \
  iproute2 ethtool tcpdump iperf3 python3 curl gnupg

echo ">>> [2/5] p4c from p4lang packages (OBS) - for the PSA-eBPF backend (p4c-ebpf)"
. /etc/os-release
echo "deb http://download.opensuse.org/repositories/home:/p4lang/xUbuntu_${VERSION_ID}/ /" \
  | sudo tee /etc/apt/sources.list.d/home-p4lang.list
curl -fsSL "https://download.opensuse.org/repositories/home:/p4lang/xUbuntu_${VERSION_ID}/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/home_p4lang.gpg
sudo apt-get update
sudo apt-get install -y p4lang-p4c

echo ">>> [3/5] p4c sources + wiring the system libbpf (eBPF runtime)"
if [ ! -d "$HOME/p4c" ]; then
  git clone --depth 1 https://github.com/p4lang/p4c.git "$HOME/p4c"
fi
RT="$HOME/p4c/backends/ebpf/runtime"
mkdir -p "$RT/install/libbpf/include/bpf"
ln -sf /usr/include/bpf/*.h "$RT/install/libbpf/include/bpf/"
mkdir -p "$RT/contrib/bpftool/include/uapi/linux"
ln -sf /usr/include/linux/*.h "$RT/contrib/bpftool/include/uapi/linux/"

echo ">>> [4/5] Building NIKSS from source"
if [ ! -d "$HOME/nikss" ]; then
  git clone --recursive https://github.com/NIKSS-vSwitch/nikss.git "$HOME/nikss"
fi
cd "$HOME/nikss"
./build_libbpf.sh
mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j"$(nproc)"
sudo make install
sudo ldconfig

echo ">>> [5/5] Tool verification"
echo -n "p4c-ebpf:  "; which p4c-ebpf || echo "MISSING"
echo -n "nikss-ctl: "; which nikss-ctl || echo "MISSING"
echo -n "clang:     "; clang --version | head -1

echo
echo "================================================================"
echo " Done. Enter: vagrant ssh"
echo " Then:   cd /vagrant/ebpf && ./compile.sh && sudo ./run_demo.sh"
echo "================================================================"
