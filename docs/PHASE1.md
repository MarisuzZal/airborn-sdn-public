# Phase 1 — forwarding + channel classification

The first working increment: the P4 SDN switch forwards traffic between nodes and
recognises the logical channels. INT, MTD and crypto are added in later phases.

## Topology (`p4app/topology.json`)

One switch `s1` and five nodes on a single `10.0.1.0/24` network (per slide 22). Static
ARP entries → no ARP traffic on the network.

| Node    | IP         | s1 port | Role            |
|---------|------------|---------|-----------------|
| hserver | 10.0.1.1   | 1       | task assignment |
| htn1    | 10.0.1.11  | 2       | Transit Node    |
| htn2    | 10.0.1.12  | 3       | Transit Node    |
| hcn1    | 10.0.1.21  | 4       | Computing Node  |
| hcn2    | 10.0.1.22  | 5       | Computing Node  |

## P4 program (`p4app/sdn_switch.p4`)

- parser Ethernet → IPv4 → TCP;
- `ipv4_lpm` — forwarding by destination IP onto the right port (the switch keeps the
  mapping; nodes have static ARP, so the switch only steers to a port);
- `channel_classify` — recognises the logical channel by TCP port (slide 8);
- `channel_ctr` — per-channel traffic counters (basis for statistics and INT);
- `[INT]` and `[MTD]` markers in the code mark the extension points.

## Logical channels (working TCP port numbers)

| Channel  | TCP port | Description             |
|----------|----------|-------------------------|
| ChTD     | 5001     | Tactical Data           |
| ChT      | 5002     | Task Assignment Control |
| ChINT    | 5003     | Telemetry (INT)         |
| ChP4     | 5004     | Control (TN/CN/switch)  |
| ChCrypto | 5005     | Crypto                  |

## Run (inside the VM)

```bash
cd ~/tutorials/exercises/airborn-sdn
make run
```

At the `mininet>` prompt:

```
mininet> pingall
mininet> hcn1 iperf -s -p 5001 &
mininet> hserver iperf -c 10.0.1.21 -p 5001 -t 3
```

Cleanup: `make stop` then `make clean`.

## Forwarding variant

Phase 1 uses the "switch in one subnet + static ARP" model — it follows slide 22 most
faithfully. The alternative is an L3 model (nodes in separate subnets, the switch acting
as a router that rewrites MACs from its own table): the `ipv4_forward` action is then
extended with `dstMac` and a TTL decrement.
