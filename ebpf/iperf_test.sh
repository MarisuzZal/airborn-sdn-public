#!/usr/bin/env bash
# iperf_test.sh
# Throughput test across the NIKSS data path.
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

set -euo pipefail

DUR="${1:-10}"

if ! ip netns list | grep -q hserver; then
  echo "No namespaces - run first: sudo ./run_demo.sh"; exit 1
fi

echo ">>> iperf3: server on hserver (10.0.1.1)"
ip netns exec hserver pkill -f "iperf3 -s" 2>/dev/null || true
sleep 0.3
ip netns exec hserver iperf3 -s -D
sleep 1

echo ">>> iperf3: client hcn1 -> hserver, ${DUR}s (traffic via the eBPF pipeline)"
ip netns exec hcn1 iperf3 -c 10.0.1.1 -t "$DUR" -i 2

ip netns exec hserver pkill -f "iperf3 -s" 2>/dev/null || true
echo ">>> measurement finished"
