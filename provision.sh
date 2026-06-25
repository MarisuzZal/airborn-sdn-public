#!/usr/bin/env bash
# provision.sh
# Provision the P4/BMv2/Mininet toolchain inside the development VM.
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

set -euo pipefail

TUTORIALS_DIR="$HOME/tutorials"
EXERCISE_LINK="$TUTORIALS_DIR/exercises/airborn-sdn"
P4VENV="$HOME/p4venv"

echo ">>> [1/5] Base packages"
sudo apt-get update -y
sudo apt-get install -y git curl gnupg python3-pip python3-venv

echo ">>> [2/5] p4lang package repository (OBS)"
. /etc/os-release
echo "deb http://download.opensuse.org/repositories/home:/p4lang/xUbuntu_${VERSION_ID}/ /" \
  | sudo tee /etc/apt/sources.list.d/home-p4lang.list
curl -fsSL "https://download.opensuse.org/repositories/home:/p4lang/xUbuntu_${VERSION_ID}/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/home_p4lang.gpg
sudo apt-get update

echo ">>> [3/5] P4 toolchain: p4c (p4c-bm2-ss), BMv2 (simple_switch_grpc), Mininet"
sudo apt-get install -y p4lang-p4c p4lang-bmv2 mininet

echo ">>> [4/5] Python venv: P4Runtime libraries + p4.tmp module + mininet"
python3 -m venv "$P4VENV"
"$P4VENV/bin/pip" install --upgrade pip
"$P4VENV/bin/pip" install grpcio "protobuf==3.20.3" p4runtime psutil "grpcio-tools==1.48.2" "setuptools<81"

rm -rf /tmp/piproto /tmp/piout
mkdir -p /tmp/piproto/p4/tmp /tmp/piout
curl -fsSL https://raw.githubusercontent.com/p4lang/PI/main/proto/p4/tmp/p4config.proto \
  -o /tmp/piproto/p4/tmp/p4config.proto
"$P4VENV/bin/python" -m grpc_tools.protoc -I /tmp/piproto --python_out=/tmp/piout \
  /tmp/piproto/p4/tmp/p4config.proto
P4PKG=$("$P4VENV/bin/python" -c "import p4; print(p4.__path__[0])")
mkdir -p "$P4PKG/tmp"
cp /tmp/piout/p4/tmp/p4config_pb2.py "$P4PKG/tmp/"
touch "$P4PKG/tmp/__init__.py"

PYVER=$("$P4VENV/bin/python" -c "import sys; print(f'python{sys.version_info[0]}.{sys.version_info[1]}')")
ln -sfn /usr/lib/python3/dist-packages/mininet "$P4VENV/lib/$PYVER/site-packages/mininet"

"$P4VENV/bin/python" -c "import mininet; from p4.v1 import p4runtime_pb2; from p4.tmp import p4config_pb2; print('importy OK')"

echo ">>> [5/5] Cloning p4lang/tutorials (utils/ framework) and wiring p4app/"
if [ ! -d "$TUTORIALS_DIR" ]; then
  git clone https://github.com/p4lang/tutorials.git "$TUTORIALS_DIR"
fi
mkdir -p "$TUTORIALS_DIR/exercises"
rm -rf "$EXERCISE_LINK"
ln -s /vagrant/p4app "$EXERCISE_LINK"

echo
echo "================================================================"
echo " Done. Enter: vagrant ssh"
echo " Then:         cd ~/tutorials/exercises/airborn-sdn && make run"
echo "================================================================"
