// sdn_switch.p4
// BMv2 (v1model) P4 data plane: L3 forwarding, channel classification, INT headers and MTD redirect.
//
// AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

#include <core.p4>
#include <v1model.p4>

const bit<16> TYPE_IPV4 = 0x0800;
const bit<8>  PROTO_TCP = 6;
const bit<8>  PROTO_UDP = 17;

const bit<16> PORT_ChTD     = 5001;
const bit<16> PORT_ChT      = 5002;
const bit<16> PORT_ChINT    = 5003;
const bit<16> PORT_ChP4     = 5004;
const bit<16> PORT_ChCrypto = 5005;

const bit<8> CH_UNKNOWN = 0;
const bit<8> CH_TD      = 1;
const bit<8> CH_T       = 2;
const bit<8> CH_INT     = 3;
const bit<8> CH_P4      = 4;
const bit<8> CH_CRYPTO  = 5;
#define NUM_CHANNELS 6

const bit<16> INT_MAGIC = 0x4954;
#define MAX_INT_HOPS 4
const bit<16> INT_SHIM_BYTES = 4;
const bit<16> INT_META_BYTES = 22;

typedef bit<9>  egressSpec_t;
typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;

header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr;
    bit<16>   etherType;
}

header ipv4_t {
    bit<4>    version;
    bit<4>    ihl;
    bit<8>    diffserv;
    bit<16>   totalLen;
    bit<16>   identification;
    bit<3>    flags;
    bit<13>   fragOffset;
    bit<8>    ttl;
    bit<8>    protocol;
    bit<16>   hdrChecksum;
    ip4Addr_t srcAddr;
    ip4Addr_t dstAddr;
}

header tcp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<32> seqNo;
    bit<32> ackNo;
    bit<4>  dataOffset;
    bit<4>  res;
    bit<8>  flags;
    bit<16> window;
    bit<16> checksum;
    bit<16> urgentPtr;
}

header udp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<16> length_;
    bit<16> checksum;
}

header int_shim_t {
    bit<16> magic;
    bit<8>  count;
    bit<8>  rsvd;
}

header int_meta_t {
    bit<32> switch_id;
    bit<16> ingress_port;
    bit<16> egress_port;
    bit<48> ingress_ts;
    bit<32> hop_latency;
    bit<24> q_depth;
    bit<8>  rsvd;
}

struct parser_metadata_t {
    bit<8> remaining;
}

struct metadata {
    bit<8>            channel_id;
    bit<32>           int_switch_id;
    parser_metadata_t parser_metadata;
}

struct headers {
    ethernet_t              ethernet;
    ipv4_t                  ipv4;
    tcp_t                   tcp;
    udp_t                   udp;
    int_shim_t              int_shim;
    int_meta_t[MAX_INT_HOPS] int_meta;
}

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        meta.channel_id = CH_UNKNOWN;
        meta.int_switch_id = 0;
        meta.parser_metadata.remaining = 0;
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default:   accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            PROTO_TCP: parse_tcp;
            PROTO_UDP: parse_udp;
            default:   accept;
        }
    }

    state parse_tcp {
        packet.extract(hdr.tcp);
        transition accept;
    }

    state parse_udp {
        packet.extract(hdr.udp);
        transition select(hdr.udp.dstPort) {
            PORT_ChINT: pre_parse_int;
            default:    accept;
        }
    }

    state pre_parse_int {
        transition select(packet.lookahead<bit<16>>()) {
            INT_MAGIC: parse_int_shim;
            default:   accept;
        }
    }

    state parse_int_shim {
        packet.extract(hdr.int_shim);
        meta.parser_metadata.remaining = hdr.int_shim.count;
        transition select(meta.parser_metadata.remaining) {
            0:       accept;
            default: parse_int_meta;
        }
    }

    state parse_int_meta {
        packet.extract(hdr.int_meta.next);
        meta.parser_metadata.remaining = meta.parser_metadata.remaining - 1;
        transition select(meta.parser_metadata.remaining) {
            0:       accept;
            default: parse_int_meta;
        }
    }
}

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    counter(NUM_CHANNELS, CounterType.packets_and_bytes) channel_ctr;

    action drop() {
        mark_to_drop(standard_metadata);
    }

    action ipv4_forward(egressSpec_t port) {
        standard_metadata.egress_spec = port;
    }

    table ipv4_lpm {
        key = { hdr.ipv4.dstAddr: lpm; }
        actions = { ipv4_forward; drop; NoAction; }
        size = 1024;
        default_action = drop();
    }

    action set_channel(bit<8> ch) {
        meta.channel_id = ch;
    }

    table channel_classify {
        key = {
            hdr.tcp.dstPort: ternary;
            hdr.tcp.srcPort: ternary;
        }
        actions = { set_channel; NoAction; }
        size = 64;
        default_action = NoAction();
    }

    table channel_classify_udp {
        key = {
            hdr.udp.dstPort: ternary;
            hdr.udp.srcPort: ternary;
        }
        actions = { set_channel; NoAction; }
        size = 64;
        default_action = NoAction();
    }

    action redirect_to_tn(egressSpec_t port) {
        standard_metadata.egress_spec = port;
    }

    table mtd_redirect {
        key = {
            standard_metadata.ingress_port: exact;
            meta.channel_id:                exact;
        }
        actions = { redirect_to_tn; NoAction; }
        size = 32;
        default_action = NoAction();
    }

    apply {
        if (hdr.ipv4.isValid()) {
            if (hdr.tcp.isValid()) {
                channel_classify.apply();
            } else if (hdr.udp.isValid()) {
                channel_classify_udp.apply();
            }
            channel_ctr.count((bit<32>)meta.channel_id);

            ipv4_lpm.apply();

            mtd_redirect.apply();
        }
    }
}

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {

    action int_enable(bit<32> switch_id) {
        meta.int_switch_id = switch_id;
    }

    table int_config {
        key = { hdr.udp.dstPort: exact; }
        actions = { int_enable; NoAction; }
        size = 16;
        default_action = NoAction();
    }

    apply {
        if (hdr.udp.isValid()) {
            switch (int_config.apply().action_run) {
                int_enable: {

                    if (!hdr.int_shim.isValid()) {
                        hdr.int_shim.setValid();
                        hdr.int_shim.magic = INT_MAGIC;
                        hdr.int_shim.count = 0;
                        hdr.int_shim.rsvd  = 0;
                        hdr.ipv4.totalLen = hdr.ipv4.totalLen + INT_SHIM_BYTES;
                        hdr.udp.length_   = hdr.udp.length_   + INT_SHIM_BYTES;
                    }

                    if (hdr.int_shim.count < MAX_INT_HOPS) {
                        hdr.int_shim.count = hdr.int_shim.count + 1;
                        hdr.int_meta.push_front(1);
                        hdr.int_meta[0].setValid();
                        hdr.int_meta[0].switch_id    = meta.int_switch_id;
                        hdr.int_meta[0].ingress_port = (bit<16>)standard_metadata.ingress_port;
                        hdr.int_meta[0].egress_port  = (bit<16>)standard_metadata.egress_port;
                        hdr.int_meta[0].ingress_ts   = standard_metadata.ingress_global_timestamp;
                        hdr.int_meta[0].hop_latency  = standard_metadata.deq_timedelta;
                        hdr.int_meta[0].q_depth      = (bit<24>)standard_metadata.deq_qdepth;
                        hdr.int_meta[0].rsvd         = 0;
                        hdr.ipv4.totalLen = hdr.ipv4.totalLen + INT_META_BYTES;
                        hdr.udp.length_   = hdr.udp.length_   + INT_META_BYTES;
                    }

                    hdr.udp.checksum = 0;
                }
            }
        }
    }
}

control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply {
        update_checksum(
            hdr.ipv4.isValid(),
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv,
              hdr.ipv4.totalLen, hdr.ipv4.identification, hdr.ipv4.flags,
              hdr.ipv4.fragOffset, hdr.ipv4.ttl, hdr.ipv4.protocol,
              hdr.ipv4.srcAddr, hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.tcp);
        packet.emit(hdr.udp);
        packet.emit(hdr.int_shim);
        packet.emit(hdr.int_meta);
    }
}

V1Switch(
    MyParser(),
    MyVerifyChecksum(),
    MyIngress(),
    MyEgress(),
    MyComputeChecksum(),
    MyDeparser()
) main;
