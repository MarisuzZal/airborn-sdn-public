# Architecture

## Nodes

* **Server** — the single point of control. It collects node telemetry, decides which
  Transit Node is active, enforces that decision in the data plane, and announces it on
  the control channel **ChP4**.
* **Transit Node (TN)** — relays the telemetry-data channel (ChTD) and the INT channel
  between Computing Nodes and the server. The deployment uses **two TNs**; exactly one is
  *active* at a time, the other is a hot *passive* standby. A TN may add its own telemetry
  to the INT chain as the packet passes through it.
* **Computing Node (CN)** — a drone endpoint that originates application telemetry. The
  deployment uses **two CNs**.

A single **P4 SDN switch** sits in the middle and forwards between all nodes. In the VM
tracks the switch is one BMv2 / NIKSS instance with a port per node; on hardware each
Raspberry Pi runs its own pipeline.

## Logical channels

| Channel | Port / proto | Direction | Purpose |
|---------|--------------|-----------|---------|
| ChTD | 5001 / TCP | CN -> TN -> server | telemetry-data payload |
| ChT  | 5002 / TCP | node -> server | node telemetry stream |
| ChINT | 5003 / UDP | CN -> TN -> server | in-band telemetry (INT) |
| ChP4 | 5004 / UDP | server -> nodes | control (active-TN announcement) |
| ChCrypto | 5005 / TCP | external | reserved for the crypto device (out of scope) |

The switch classifies every packet into one of these channels both on the destination
port and on the source port (for return traffic), and counts per-channel traffic.

## In-band Network Telemetry (INT)

INT carries **abstract application telemetry**, not network counters. Each hop appends a
fixed 10-byte metadata record:

```
node_id (1B) | battery (1B) | cpu (1B) | queue_len (1B) | ingress_timestamp (6B)
```

The eBPF data plane implements a **2-slot INT-MD** layout: slot 0 is filled by the
Computing Node on entry and slot 1 by the active Transit Node, so the collector at the
server sees the path `CN -> active TN`. The values come from PSA registers
(`battery_reg`, `cpu_reg`, `queue_reg`) that an on-node agent updates at random.

After the INT shim and metadata are pushed, the IPv4 `totalLen` changes, so the data
plane recomputes the IPv4 checksum in the deparser.

## Moving Target Defense (MTD)

The server rotates which TN is active — either on a fixed period or reactively when the
active TN's battery drops below a threshold and the standby is healthier. The decision is
enforced by programming the `mtd_redirect` table (NIKSS) / the equivalent BMv2 entries,
and announced over ChP4. The relays react by switching their active/passive role. At the
INT collector this shows as the second INT hop following the active TN as it rotates
(`CN -> TN1` then `CN -> TN2`).

## Control plane

* **Reference track** — table entries are loaded over **P4Runtime** (`s1-runtime.json`).
* **Performance track** — `nikss-ctl` programs tables, registers and counters; the
  `server_decider` reads TN battery registers, writes `mtd_redirect` directly and sends
  ChP4 control packets.

## Out of scope

Encryption (ChCrypto) is delegated to an external device between each node and its radio
transmitter, and is intentionally not implemented in this prototype.
