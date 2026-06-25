#!/usr/bin/env bash
# run_demo.sh
# Bring up a network-namespace topology, load the NIKSS pipeline and install forwarding/channel/INT/MTD entries.
#
# AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

set -euo pipefail

PIPE=1
OBJ="$(cd "$(dirname "$0")" && pwd)/build/sdn_switch_psa.o"

NODES=(
  "hserver 10.0.1.1  08:00:00:00:00:01"
  "htn1    10.0.1.11 08:00:00:00:00:11"
  "htn2    10.0.1.12 08:00:00:00:00:12"
  "hcn1    10.0.1.21 08:00:00:00:00:21"
  "hcn2    10.0.1.22 08:00:00:00:00:22"
)

cleanup() {
  for entry in "${NODES[@]}"; do
    set -- $entry; ns=$1
    ip netns del "$ns" 2>/dev/null || true
    ip link del "veth-$ns" 2>/dev/null || true
  done
  nikss-ctl pipeline unload id $PIPE 2>/dev/null || true
}

if [ "${1:-}" = "clean" ]; then cleanup; echo "cleaned up"; exit 0; fi

cleanup
echo ">>> Loading PSA-eBPF pipeline"
nikss-ctl pipeline load id $PIPE "$OBJ"

port=1
declare -A PORTOF
declare -A NIFX
for entry in "${NODES[@]}"; do
  set -- $entry; ns=$1; ip4=$2; mac=$3
  ip netns add "$ns"
  ip link add "veth-$ns" type veth peer name "eth0" netns "$ns"
  ip link set "veth-$ns" up
  ip netns exec "$ns" ip link set dev eth0 address "$mac"
  ip netns exec "$ns" ip addr add "$ip4/24" dev eth0
  ip netns exec "$ns" ip link set dev eth0 up
  ip netns exec "$ns" ethtool -K eth0 gso off gro off tso off tx off rx off 2>/dev/null || true
  for other in "${NODES[@]}"; do
    set -- $other; ons=$1; oip=$2; omac=$3
    [ "$ons" = "$ns" ] || ip netns exec "$ns" ip neigh add "$oip" lladdr "$omac" dev eth0
  done
  nikss-ctl add-port pipe $PIPE dev "veth-$ns"
  ethtool -K "veth-$ns" gso off gro off tso off tx off rx off 2>/dev/null || true
  PORTOF[$ip4]=$(cat /sys/class/net/veth-$ns/ifindex)
  NIFX[$ns]=${PORTOF[$ip4]}
  echo "  $ns ($ip4) -> veth-$ns ifindex ${PORTOF[$ip4]}"
  port=$((port+1))
done

{
  printf '{\n'
  fst=1
  for entry in "${NODES[@]}"; do
    set -- $entry; n=$1
    if [ $fst -eq 1 ]; then fst=0; else printf ',\n'; fi
    printf '  "%s": %s' "$n" "${NIFX[$n]}"
  done
  printf '\n}\n'
} > /tmp/airborn_ports.json
echo ">>> Port map -> /tmp/airborn_ports.json"

echo ">>> Forwarding entries (dst IP -> port ifindex)"
for entry in "${NODES[@]}"; do
  set -- $entry; ip4=$2
  nikss-ctl table add pipe $PIPE ingress_ipv4_lpm action name ingress_ipv4_forward \
    key "${ip4}/32" data "${PORTOF[$ip4]}"
done

echo ">>> Channel classification entries (dst port -> channel)"
for pair in "5001 1" "5002 2" "5004 4" "5005 5"; do
  set -- $pair
  nikss-ctl table add pipe $PIPE ingress_channel_classify_tcp action name ingress_set_channel \
    key $1 data $2
done
nikss-ctl table add pipe $PIPE ingress_channel_classify_udp action name ingress_set_channel \
  key 5003 data 3

echo ">>> Return-traffic classification entries (src port -> channel)"
for pair in "5001 1" "5002 2" "5004 4" "5005 5"; do
  set -- $pair
  nikss-ctl table add pipe $PIPE ingress_channel_classify_tcp_src action name ingress_set_channel \
    key $1 data $2
done
nikss-ctl table add pipe $PIPE ingress_channel_classify_udp_src action name ingress_set_channel \
  key 5003 data 3

echo ">>> Mapping ports to node_id (ifindex -> id)"
nikss-ctl table add pipe $PIPE ingress_node_map action name ingress_set_node key ${NIFX[hcn1]} data 0
nikss-ctl table add pipe $PIPE ingress_node_map action name ingress_set_node key ${NIFX[hcn2]} data 1
nikss-ctl table add pipe $PIPE ingress_node_map action name ingress_set_node key ${NIFX[htn1]} data 2
nikss-ctl table add pipe $PIPE ingress_node_map action name ingress_set_node key ${NIFX[htn2]} data 3

echo ">>> INT entry (channel ChINT 5003 -> int_enable)"
nikss-ctl table add pipe $PIPE ingress_int_config action name ingress_int_enable key 5003

echo
echo ">>> Test: ping hcn1 -> hserver"
ip netns exec hcn1 ping -c3 10.0.1.1 || true
echo
echo "Cleanup:  sudo $0 clean"
