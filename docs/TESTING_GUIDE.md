# Tester guide — AirBorn SDN

One document for the **functional tester** and the **penetration tester**. Part I walks
through bringing up the environment and verifying that the system works. Part II describes
the attack surface for security testing.

---

## Part I — bring-up and functional tests

### 0. Choosing a track

* **BMv2 (reference)** — the most readable, best for learning and debugging. Start here.
* **eBPF / NIKSS (performance)** — the same logic in the kernel layer; this is what we move
  to hardware.
* **Raspberry Pi (hardware)** — the eBPF object from the VM loaded onto 4× RPi 5.

The first functional tests need neither hardware nor Wi-Fi.

### 1. BMv2 in the VM

```bash
vagrant up            # the first run is long (toolchain build, min. 4 GB RAM)
vagrant ssh
cd ~/tutorials/exercises/airborn-sdn
make run              # mininet> prompt
```

Checklist (BMv2):

- [ ] `pingall` — full connectivity (5 nodes: hserver, htn1, htn2, hcn1, hcn2)
- [ ] ChTD traffic: `hcn1 iperf -s -p 5001 &` + `hserver iperf -c 10.0.1.21 -p 5001 -t 3`
- [ ] per-channel counters grow according to the ports (ChTD/ChT/ChINT/ChP4)
- [ ] the INT collector (`utils/int_collector.py`) shows hop-by-hop metadata
- [ ] the MTD controller (`utils/mtd_controller.py`) rotates the active TN

Cleanup: `make stop` → `make clean`.

### 2. eBPF / NIKSS in the VM

```bash
cd /vagrant/ebpf
./compile.sh                      # -> build/sdn_switch_psa.o
sudo ./run_demo.sh                # netns topology + pipeline + entries
```

Checklist (eBPF):

- [ ] `run_demo.sh` finishes with a successful `hcn1 -> hserver` ping
- [ ] telemetry agents: `sudo ip netns exec hcn1 python3 utils/drone_agent.py 0`
- [ ] INT collector: `sudo ip netns exec hserver python3 utils/int_app_collector.py 5003`
      shows **2 INT slots** (`hcn1 -> htn1/htn2`)
- [ ] server decision maker: `sudo python3 utils/server_decider.py` (in the default ns) —
      reads TN battery registers, updates `mtd_redirect`, sends ChP4
- [ ] after an MTD decision the second INT hop follows the active TN (TN1 ↔ TN2 rotation)
- [ ] throughput: `sudo ./iperf_test.sh`

### 3. Raspberry Pi (hardware)

```bash
bash rpi/prepare_node.sh                         # toolchain + NIKSS (once per board)
sudo nikss-ctl pipeline load id 1 ~/sdn_switch_psa.o
```

Checklist (hardware):

- [ ] the object built on x86 loads on ARM64 (confirms BPF portability)
- [ ] control-plane operations work: `table add/get`, `register set/get`, `counter get`
- [ ] (optional) Wi-Fi via `rpi/wifi_roaming_setup.sh` — see `docs/NOTES_PROBLEMS.md`
- [ ] the first hardware forwarding test CN ↔ RPi(switch) ↔ server in `10.0.1.0/24`
      with static ARP

---

## Part II — attack surface (penetration testing)

> **Design assumption:** cryptography is **out of scope** (it is provided by an external
> device between the node and the radio). In the prototype, channel traffic is
> **unencrypted and unauthenticated** — a deliberate scope choice, and at the same time the
> main area to assess.

### Model and channels

All channels (ChTD 5001, ChT 5002, ChINT 5003, ChP4 5004, ChCrypto 5005) run in clear text.
The server is the **sole decision maker**; nodes trust whatever arrives on ChP4.

### Vectors to check

1. **Spoofing ChP4 (control).** ChP4 (UDP/5004) is unauthenticated. Injecting a forged
   control packet may force the rotation/selection of the active TN without the server's
   consent. Test: send your own ChP4 packet to a TN and check whether it changes role.
2. **Telemetry/register spoofing for INT.** Battery/CPU/queue values drive the server's MTD
   decision. Forging a low battery for the active TN may force a switch (an attack on
   availability / on route control). Test: lower a battery register and watch the
   `server_decider` decision.
3. **Injecting/altering INT-MD.** No integrity on the INT metadata — a hop can be
   added/changed. Check how the collector reacts to extra or inconsistent slots.
4. **DoS on the active TN.** Since all ChTD/ChINT goes through the active TN, overloading it
   — or "subtly" understating its telemetry — is a vector against availability and against
   the MTD logic at once.
5. **Static ARP / no ARP on the switch.** Endpoints have static ARP entries. Assess the risk
   of spoofing (ARP is not a defence mechanism here — it is a lab simplification).
6. **Control-plane surface.** Access to `nikss-ctl` / P4Runtime = full control over tables,
   registers and `mtd_redirect`. Assess the isolation of the switch host.
7. **The "crypto out of scope" boundary.** Verify the assumption: is there actually an
   encrypting device between the node and the transmitter, and does nothing sensitive leak
   before it?

### What to prepare

Two machines/namespaces attached to the same switch (BMv2 or NIKSS), with tools:
`scapy`/`python` (crafting ChP4/ChINT packets), `tcpdump`, `nikss-ctl` (inspecting counters
and registers). Starting point: bring up the eBPF track (Part I.2), enable `server_decider`,
then try to influence its decisions with vectors 1–4.

Environment problems (toolchain, hardware, Wi-Fi) and their workarounds are in
[`NOTES_PROBLEMS.md`](NOTES_PROBLEMS.md).

To build an independent controller, or to craft ChP4/INT packets, see the
[`CONTROL_PLANE.md`](CONTROL_PLANE.md) protocol contract.
