# Control plane & protocol contract

Everything needed to build an **independent SDN controller** — or attack tooling — for
AirBorn SDN, without reading the reference implementation. Covers the control-plane API
(tables, actions, registers, counters), the **ChP4** control message and the **INT** wire
format. NIKSS object names carry the `ingress_` control prefix; the BMv2 reference uses the
same logical objects under `MyIngress.<name>` via P4Runtime.

## 1. Topology constants

- Data-plane subnet `10.0.1.0/24`, static ARP (the switch does not answer ARP).
- `node_id`: `0` = CN1, `1` = CN2, `2` = TN1, `3` = TN2 (the server is an INT sink, no node_id).
- Example IPs: server `10.0.1.1`, TN1 `10.0.1.11`, TN2 `10.0.1.12`, CN1 `10.0.1.21`, CN2 `10.0.1.22`.

## 2. Logical channels -> channel_id

| Channel | Port / proto | channel_id |
|---------|--------------|------------|
| (unknown) | — | 0 |
| ChTD | 5001 / TCP | 1 |
| ChT  | 5002 / TCP | 2 |
| ChINT | 5003 / UDP | 3 |
| ChP4 | 5004 / UDP | 4 |
| ChCrypto | 5005 / TCP | 5 |

## 3. Control-plane API (NIKSS / eBPF)

Pipeline id `<P>` (the demo uses `1`).

```
nikss-ctl pipeline load id <P> sdn_switch_psa.o
nikss-ctl add-port  pipe <P> dev <iface>
nikss-ctl table add pipe <P> <table> action name <action> key <...> data <...>
nikss-ctl table del pipe <P> <table> key <...>
nikss-ctl register set/get pipe <P> <reg> index <i> [value <v>]
nikss-ctl counter get pipe <P> <ctr>
```

### Tables

| Table | Key | Action (params) | Meaning |
|-------|-----|-----------------|---------|
| `ingress_ipv4_lpm` | `ipv4.dstAddr` (lpm) | `ingress_ipv4_forward(port)` / `drop` | L3 forward to an egress port; default = drop |
| `ingress_channel_classify_tcp` | `tcp.dstPort` (exact) | `ingress_set_channel(ch)` | classify by TCP dst port |
| `ingress_channel_classify_tcp_src` | `tcp.srcPort` (exact) | `ingress_set_channel(ch)` | return-traffic classify |
| `ingress_channel_classify_udp` | `udp.dstPort` (exact) | `ingress_set_channel(ch)` | classify by UDP dst port |
| `ingress_channel_classify_udp_src` | `udp.srcPort` (exact) | `ingress_set_channel(ch)` | return-traffic classify |
| `ingress_node_map` | `ingress_port` ifindex (exact) | `ingress_set_node(id)` | map ingress port -> node_id (for INT) |
| `ingress_int_config` | `udp.dstPort` (exact) | `ingress_int_enable` | enable INT on a channel (key `5003`) |
| `ingress_mtd_redirect` | `ingress_port` (exact) + `channel_id` (exact) | `ingress_redirect_to_tn(port)` | MTD: steer ChTD/ChINT entering server/CN ports to the active TN port |

### Registers (index = node_id, 0..7, 32-bit)

| Register | Value |
|----------|-------|
| `ingress_battery_reg` | battery [%] |
| `ingress_cpu_reg` | CPU load [%] |
| `ingress_queue_reg` | queue length |

`register get` returns the value as hex JSON: `j["<reg>"][0]["value"]["field0"]`.

### Counter

`ingress_channel_ctr` — packets per `channel_id` (index 0..5).

## 4. ChP4 control message (server -> nodes, UDP/5004)

The server announces which TN is active. One UDP datagram, JSON, UTF-8:

```json
{"active": "tn1", "active_ip": "10.0.1.11", "seq": 7}
```

- `active_ip` — IP of the TN that should be active; a node compares it to its own IP and
  becomes **ACTIVE** if equal, otherwise **LISTEN**.
- `seq` — monotonically increasing sequence number.
- **No authentication or signature** — any host on the segment can forge it (a deliberate
  scope gap; encryption is the external ChCrypto device).

A minimal controller sends this datagram to every TN (`10.0.1.11`, `10.0.1.12`) after each
decision, and enforces the same decision in `ingress_mtd_redirect`.

## 5. INT wire format (ChINT, UDP/5003)

Appended after the UDP header: a 4-byte shim, then up to two 10-byte metadata entries.

Shim (4 B):

| magic (2 B) | count (1 B) | rsvd (1 B) |
|-------------|-------------|------------|
| `0x4954` ("IT") | number of entries | 0 |

Metadata entry (10 B), repeated `count` times (slot 0 = CN, slot 1 = active TN):

| node_id (1 B) | battery (1 B) | cpu (1 B) | queue_len (1 B) | ingress_ts (6 B, big-endian µs) |
|---------------|---------------|-----------|-----------------|---------------------------------|

Collector logic: read `count`, then `count × 10 B`; map `node_id` to a name via section 1.

## 6. Build-your-own-controller checklist

1. **Read** TN telemetry: `nikss-ctl register get pipe 1 ingress_battery_reg index <node_id>`.
2. **Decide** the active TN (your policy — e.g. lowest battery triggers a switch).
3. **Enforce**: program `ingress_mtd_redirect` for each (server/CN ingress port × ChTD[, ChINT])
   to the active TN port; delete stale entries.
4. **Announce**: send the section-4 ChP4 JSON to both TNs.
5. **Verify** (optional): `nikss-ctl counter get pipe 1 ingress_channel_ctr`.

## 7. Notes for security testing

ChP4 and INT are unauthenticated and unencrypted. Forging a ChP4 datagram can flip the
active TN; forging a low battery register value (or a spoofed INT slot) can drive the
server's MTD decision. Both are primary vectors — see `TESTING_GUIDE.md`.
