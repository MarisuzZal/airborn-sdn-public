# AirBorn SDN

A working prototype of the **AirBorn SDN** system (Software Defined Networks, Poznan
University of Technology). Drones carry a **P4-programmable SDN switch**; the network
is built from **Computing Nodes (CN)**, **Transit Nodes (TN)** and a **server**. The
switch forwards traffic, classifies it into logical channels, carries **In-band Network
Telemetry (INT)** and supports **Moving Target Defense (MTD)**.

The telemetry transported by INT is **abstract application telemetry** — battery level,
CPU load and task-queue length — produced randomly by an on-node application, not raw
network counters. The **server is the sole decision maker**: it reads node telemetry,
decides which TN is active and announces the decision over the control channel **ChP4**.
Cryptography is **out of scope** here (it is handled by an external device placed between
the node and the radio transmitter).

## Tracks

The same design is realised on three layers, from easiest to closest-to-hardware:

| Track | Folder | Data plane | Runtime |
|-------|--------|-----------|---------|
| Reference | `p4app/` | P4 for **BMv2** (v1model) | Mininet + P4Runtime, in a VM |
| Performance | `ebpf/` | P4 for **PSA / eBPF** via **NIKSS** | Linux network namespaces, in a VM |
| Hardware | `rpi/` + `ebpf/` | the eBPF object on **ARM64** | **Raspberry Pi 5** nodes |

The eBPF object is architecture-independent BPF bytecode, so the program compiled in the
x86 VM loads unchanged on the ARM64 Raspberry Pi.

## Repository layout

```
airborn-sdn/
├── p4app/                 # Reference track (BMv2 + Mininet + P4Runtime)
│   ├── sdn_switch.p4
│   ├── topology.json
│   ├── s1-runtime.json
│   ├── Makefile
│   └── utils/             # cn_report, int_collector, mtd_controller, tn_relay
├── ebpf/                  # Performance track (PSA-eBPF / NIKSS)
│   ├── p4src/sdn_switch_psa.p4
│   ├── compile.sh         # p4c-ebpf -> clang -> sdn_switch_psa.o
│   ├── run_demo.sh        # netns topology + pipeline + table entries
│   ├── iperf_test.sh
│   ├── provision_ebpf.sh
│   ├── Vagrantfile
│   └── utils/             # drone_agent, int_app_collector, mtd_controller_ebpf, server_decider
├── rpi/                   # Raspberry Pi bring-up
│   ├── prepare_node.sh    # toolchain + NIKSS on Ubuntu Server 24.04 ARM64
│   └── wifi_roaming_setup.sh
├── docs/                  # ARCHITECTURE, BMV2, EBPF_VM, RASPBERRY_PI
├── Vagrantfile            # BMv2 VM
└── provision.sh           # BMv2 toolchain provisioning
```

## Logical channels

| Channel | Port / proto | Purpose |
|---------|--------------|---------|
| ChTD | 5001 / TCP | telemetry-data relayed by the active TN |
| ChT  | 5002 / TCP | node telemetry stream |
| ChINT | 5003 / UDP | in-band telemetry (INT) |
| ChP4 | 5004 / UDP | control channel (server → nodes) |
| ChCrypto | 5005 / TCP | reserved for the external crypto device (out of scope) |

## Quick start

Start with the **[tester guide](docs/TESTING_GUIDE.md)** — it brings up all three tracks,
lists functional-test checklists and describes the attack surface for security testing.

* System overview and packet formats: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
* Reference track (BMv2), per phase: [`docs/PHASE1.md`](docs/PHASE1.md),
  [`docs/PHASE2.md`](docs/PHASE2.md), [`docs/PHASE3.md`](docs/PHASE3.md)
* Performance + hardware track (eBPF / NIKSS / Raspberry Pi): [`docs/EBPF.md`](docs/EBPF.md)
* Tester guide (bring-up + security): [`docs/TESTING_GUIDE.md`](docs/TESTING_GUIDE.md)
* Engineering notes and pitfalls: [`docs/NOTES_PROBLEMS.md`](docs/NOTES_PROBLEMS.md)
* Control-plane & protocol contract: [`docs/CONTROL_PLANE.md`](docs/CONTROL_PLANE.md)

## Notes

Device-specific values (Wi-Fi SSID, dongle interface name, MAC addresses) in `rpi/` are
**placeholders** (`YOUR_SSID`, `wlxXXXXXXXXXXXX`, `AA:BB:CC:...`). Replace them with your
own before running. The lab uses the private `10.0.1.0/24` address range for the data
plane; adjust to taste.

## References

* [p4lang/tutorials](https://github.com/p4lang/tutorials) — Mininet + BMv2 + P4Runtime framework
* [p4lang/behavioral-model](https://github.com/p4lang/behavioral-model) — BMv2
* [NIKSS-vSwitch/nikss](https://github.com/NIKSS-vSwitch/nikss) — Native In-Kernel P4 Software Switch
* [p4lang/p4c](https://github.com/p4lang/p4c) — P4 compiler (incl. the eBPF backend)
