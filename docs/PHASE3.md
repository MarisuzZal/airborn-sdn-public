# Phase 3 — Moving Target Defense (MTD)

Implements slides 27–30: at any moment only one TN is active (transmitting), the others
listen; the MTD mechanism, at random or cyclic moments, designates a new active TN, and
the traffic of the protected ChTD channel always flows through the currently active node.

## How it works

1. **`mtd_redirect` table (P4, ingress)** — key: `(ingress_port, channel_id)`. For ChTD
   traffic entering on the server port (1) and CN ports (4, 5) it overrides the `ipv4_lpm`
   decision, steering the packet to the active TN port. Traffic returning from a TN (ports
   2, 3) is not redirected — hence no loops and a simple logical topology:
   `CN → s1 → active_TN → s1 → server` (and symmetrically for the return path, thanks to
   classification on `srcPort 5001`).

2. **MTD controller** (`utils/mtd_controller.py`, run in the VM) — rotates the active TN
   every `--period` seconds (with an optional `--random`), rewriting the `mtd_redirect`
   entries and publishing the state in `/tmp/mtd_active.json`. In the prototype the state
   file stands in for a ChP4 message (the Mininet nodes share a filesystem); the tables are
   rewritten over the local BMv2 management interface (Thrift) — in the target system both
   functions are taken over by P4Runtime + in-band messages.

3. **TN relay** (`utils/tn_relay.py`, on htn1/htn2) — a raw AF_PACKET socket: in the ACTIVE
   state it transparently retransmits ChTD frames (TCP/5001) not addressed to itself; in
   the LISTEN state it only counts them (slide 28). Every 5 s it sends an **aggregated
   report** on ChINT (UDP/5003) — the switch appends INT telemetry to it (slide 8: TN
   reports).

## Run and test

Terminal 1 (Mininet):

```
make run
mininet> htn1 python3 /vagrant/p4app/utils/tn_relay.py htn1 tn1 &
mininet> htn2 python3 /vagrant/p4app/utils/tn_relay.py htn2 tn2 &
mininet> hserver python3 /vagrant/p4app/utils/int_collector.py > /tmp/int.log 2>&1 &
mininet> hserver iperf -s -p 5001 > /tmp/iperf_srv.log 2>&1 &
mininet> hcn1 iperf -c 10.0.1.1 -p 5001 -t 60 -i 5 > /tmp/iperf_cli.log 2>&1 &
```

Terminal 2 (a second `vagrant ssh`):

```bash
python3 /vagrant/p4app/utils/mtd_controller.py --period 10
```

## Expected observations

- The controller logs rotations: `#1: active TN = tn1 ...`, `#2: active TN = tn2 ...`
- The relays report state changes, and the `relayed` counter grows only on the ACTIVE TN
  and stalls once the other node takes over.
- `iperf` (60 s) survives the rotations — TCP smooths the brief hiccups (slide 30: ordering
  is left to higher layers).
- In `/tmp/int.log`, aggregated TN reports (`role: tn`) with INT telemetry; the report's
  `in` field shows the active TN port.
- After stopping the controller (Ctrl+C) the redirects are cleared and traffic returns to
  the direct paths.

## Verifying the redirect on the port counter

```bash
echo "counter_read MyIngress.channel_ctr 1" | simple_switch_CLI --thrift-port 9090
```

The ChTD counter grows ~2x faster with MTD enabled (each ChTD packet crosses the switch
twice: CN→TN and TN→server).

## Measurement results (rotation every 10 s)

- Controller rotation: clean, cyclic tn1 ↔ tn2.
- Relays: the `relayed` counter grows only on the ACTIVE TN and freezes after switching to
  listen — the transmission "baton" travels with the rotation.
- ChTD iperf (60 s): the connection **survived all rotations** (no TCP session reset),
  3.41 MB transferred, average 299 Kbit/s versus ~1.0–1.5 Mbit/s at the start. The drop is
  due to in-flight packet loss at each hard switch (TCP retransmits and shrinks the window).

## Known limitations and directions

1. **Hard switch instead of overlap.** The controller swaps the table atomically — for a
   moment no TN forwards, so in-flight packets are lost. Slide 30 assumes a handover with a
   grace period (the new TN starts before the old one drains its buffers; ordering is fixed
   by higher layers). Adding an overlap window would significantly reduce loss — a tuning
   candidate.
2. **Passive TNs collect little data** (`collected` ≈ 4–6). In the wired model the switch
   unicasts ChTD only to the active TN port, so passive nodes really do not see the traffic.
   In the target radio system passive TNs "hear" all traffic (broadcast) and collect from
   it — a prototype divergence from slide 28.
