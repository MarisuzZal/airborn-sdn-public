# Phase 2 — In-band Network Telemetry (INT-MD)

Implements slides 23–26: the switch appends telemetry metadata to packets of the ChINT
channel; a collector assembles CN reports with network telemetry.

## Design decision: ChINT over UDP

Inserting INT bytes on the fly into a TCP stream breaks sequence numbering, so the ChINT
channel runs over **UDP/5003** (the other channels stay TCP). Telemetry tolerates the loss
of individual reports.

## INT format (after the UDP header, before the data)

Shim (4 B): `magic=0x4954 ("IT") | count(1B) | rsvd(1B)`

Metadata entry (22 B, max 4 entries — a stack, newest first):

| Field | Size | Meaning |
|-------|------|---------|
| switch_id | 4 B | switch identifier (from the control plane) |
| ingress_port / egress_port | 2+2 B | packet ingress/egress ports |
| ingress_ts | 6 B | ingress timestamp [µs] |
| hop_latency | 4 B | time spent in the switch [µs] |
| q_depth | 3 B | queue depth at egress [packets] |
| rsvd | 1 B | alignment |

The switch updates `ipv4.totalLen` and `udp.length` and zeroes the UDP checksum (allowed
in IPv4). The `MyEgress.int_config` table (control plane) decides which packets are
covered by INT — entry: `dstPort 5003 → int_enable(switch_id=1)`.

## Important parser detail

The parser detects the presence of INT with a **lookahead** (checking the `0x4954` magic
after the UDP header) rather than by port number alone — fresh CN reports do not yet carry
a shim, and without this test the parser would consume application data as a bogus INT
header.

## Software components

- `p4app/utils/cn_report.py` — CN report sender (JSON over UDP/5003: name, report number,
  load average, time).
- `p4app/utils/int_collector.py` — collector: parses the shim + INT stack, prints the
  application and network report.

## Run and test (in the VM)

```bash
cd ~/tutorials/exercises/airborn-sdn
make run
```

In Mininet (collector on the server, reports from both CNs):

```
mininet> hserver python3 /vagrant/p4app/utils/int_collector.py &
mininet> hcn1 python3 /vagrant/p4app/utils/cn_report.py hcn1 10.0.1.1 &
mininet> hcn2 python3 /vagrant/p4app/utils/cn_report.py hcn2 10.0.1.1 &
```

Expected output (about every 2 s on the console):

```
[10.0.1.21] {'node': 'hcn1', 'seq': 3, 'load1': 0.12, 'ts': ...}  ||  INT: sw=1 4->1 lat=43us q=0
```

Verify the ChINT channel counters (a second `vagrant ssh` terminal):

```bash
echo "counter_read MyIngress.channel_ctr 3" | simple_switch_CLI --thrift-port 9090
```

## Limitations of this phase

- One switch = an INT stack with a single entry; the format supports up to 4 hops (ready
  for multi-switch topologies).
- TN reports (aggregated, slide 8) arrive in Phase 3 together with the MTD logic.
