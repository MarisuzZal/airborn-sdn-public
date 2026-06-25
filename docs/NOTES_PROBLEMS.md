# Engineering notes — problems encountered and conclusions

A log of problems solved while building Phases 1–3 (VM environment, BMv2 + Mininet), the
eBPF track and the Raspberry Pi bring-up, together with a baseline of behaviours a
functional tester should look for.

## 1. Environment problems (installation and toolchain)

| # | Problem | Symptom | Fix |
|---|---------|---------|-----|
| 1 | No p4lang packages for Ubuntu 24.04 | `curl 404` on the OBS repo | Build the VM on Ubuntu 22.04 LTS; install from apt packages instead of source |
| 2 | Vagrant 2.4.1 does not detect VirtualBox 7.1+ | "No usable default provider" | Update Vagrant to 2.4.9 |
| 3 | Source provisioning failed silently | no `p4c-bm2-ss` despite "success" | Switch to the p4lang apt packages (OBS) |
| 4 | Relative tutorials-framework paths | `../../utils/Makefile: No such file` | Absolute paths in the Makefile (`TUTORIALS ?= $(HOME)/tutorials`) |
| 5 | The packaged p4c does not know `.txtpb` | "Could not detect p4runtime info file format" | Custom compile rule → p4info as `.txt` + matching path in `s1-runtime.json` |
| 6 | Missing `p4.tmp.p4config_pb2` module | `ModuleNotFoundError: p4.tmp` | Generate the module from `p4config.proto` (grpc_tools.protoc) during provisioning |
| 7 | protobuf version conflict (system vs pip) | "Descriptors cannot be created directly" | Dedicated venv `~/p4venv`, pinned `protobuf==3.20.3`, `grpcio-tools==1.48.2`, `setuptools<81` |
| 8 | Removing python3-protobuf wanted to delete the whole toolchain | apt proposes removing `p4lang-*` | Do NOT remove system packages; isolate with the venv |
| 9 | Host names without an "h" prefix | `AssertionError` in `run_exercise.py` | Names `hserver, htn1, htn2, hcn1, hcn2` |
| 10 | `_comment` objects in `table_entries` | `KeyError: 'action_params'` | Remove the comment objects from `s1-runtime.json` |
| 11 | CRLF line endings after copying from Windows | `$'\r': command not found`, make errors | `sed -i 's/\r$//'` + `.gitattributes` with `eol=lf` |
| 12 | Truncated `$<` when pasting the make rule | `cc1: fatal error: $: No such file` | A rule ending in `$*.p4` instead of `$<` |

## 2. Design problems (P4 logic)

| # | Problem | Symptom | Fix |
|---|---------|---------|-----|
| 13 | INT inserted into a TCP stream would break sequence numbering | — (design decision) | ChINT channel over UDP, not TCP |
| 14 | The parser read application data as a bogus INT shim | "INT: no metadata", the switch did not append metadata | Lookahead of the `0x4954` magic before parsing the shim |
| 15 | Mininet substitutes the host name in argv with an IP | `'node': '10.0.1.21'` instead of `cn1` | Node label as a separate argument, not the host name |

## 3. What a functional tester should detect (baseline)

Areas where a thorough functional test should reveal limitations or edge behaviours.

### Forwarding and classification
- No match in `ipv4_lpm` → the packet is dropped (default `drop` action); test traffic to
  an address outside the table.
- Forwarding assumes static ARP entries on the nodes; no ARP handling in P4. What happens
  after clearing an ARP entry on a host?
- Traffic on ports outside 5001–5005 falls into the `CH_UNKNOWN` channel (counter index 0)
  — it is not classified.
- The switch does not decrement TTL (close to L2 behaviour); loop protection rests on the
  table design, not on TTL.

### INT (Phase 2)
- Metadata is appended only when `int_config` matches `dstPort 5003` — ChINT traffic on a
  different port gets no telemetry.
- A packet is treated as carrying INT solely on the basis of the `0x4954` magic (no
  authentication, no UDP checksum) — easy to forge or confuse.
- The INT stack is limited to 4 entries; behaviour past the limit (count stops growing).

### MTD (Phase 3)
- Without a running MTD controller, ChTD traffic takes the direct path (the `mtd_redirect`
  table is empty) — distinguish the two modes.
- A hard switch causes a ~5× throughput drop and packet loss at each rotation (measured:
  1.0–1.5 Mbit/s → ~0.3 Mbit/s). The TCP session does not reset, though.
- A passive TN collects negligible data (`collected` ≈ a few) — a result of the wired model
  (unicast only to the active TN) rather than radio broadcast.
- Random rotation (`--random`) vs cyclic — a difference in the loss distribution.

### Performance and stability
- The BMv2 throughput ceiling ~1 Mbit/s — it is an interpreter, not a measure of the target
  solution (hence the migration to eBPF/hardware).
- Behaviour under parallel traffic on multiple channels (TCP + UDP ChINT + MTD).

## 4. Hardware problems (Raspberry Pi)

- **OS image:** use Ubuntu **Server** 24.04 arm64 (not Desktop). A fresh Server can lack the
  `noble-updates` suite → broken dependencies; `prepare_node.sh` adds it itself.
- **SSH:** the minimal image has no `openssh-server` → installed in `prepare_node.sh`.
- **apt noninteractive:** `iperf3` prompts for a daemon → `DEBIAN_FRONTEND=noninteractive`.
- **BPF portability:** the `sdn_switch_psa.o` object built on x86 loads on ARM64 with no
  recompilation — confirmed on hardware (`nikss-ctl pipeline load`).

## 5. Wi-Fi problems (USB dongle RTL8822BU, in-kernel `rtw88_8822bu` driver)

The order of symptoms and fixes (from bringing up a node):

- **The built-in `wlan0` sees 0 networks** inside a metal case (a Faraday cage) → use a USB
  dongle.
- **Two `wpa_supplicant` instances** (wlan0 from cloud-init + the dongle) → `EBUSY` on scan;
  remove the `wifis` block from `50-cloud-init.yaml` and disable cloud-init network
  management.
- **A hidden SSID** triggers `EBUSY` on rtw88-USB → the **SSID must be broadcast** (that was
  the condition for association). In the script, `hidden: false`.
- **WPA3/SAE** would not associate on this dongle → **WPA2/psk** (a mixed WPA2/WPA3 network).
- **Power-save** makes the carrier flap and DHCP never complete → a `power_save off` service
  (requires `iw` installed; without it the command silently fails).
- **operstate DORMANT:** rtw88-USB does not report the link as "up", so systemd-networkd
  never starts DHCP at boot → a **`wifi-dhcp-kick` service** kicks DHCP after association
  until networkd takes a lease (metric 600, dynamic, renewable). Survives reboot.
- **No OFFER despite association:** a managed Wi-Fi access point may apply DHCP guarding,
  client isolation or band steering. The simplest fix is a fixed-IP reservation for the
  dongle MAC in the access point/controller.

All of the above workarounds are wired into `rpi/wifi_roaming_setup.sh`. Wi-Fi is not
required for forwarding tests — nodes are managed over `eth0`.
