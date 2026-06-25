// sdn_switch_psa.p4
// PSA P4 data plane for NIKSS/eBPF: forwarding, channels, 2-slot INT, MTD redirect and telemetry registers.
//
// AirBorn SDN - Software Defined Networks demonstrator (Poznan University of Technology).

#include <core.p4>
#include <psa.p4>

typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;

const bit<16> TYPE_IPV4 = 0x0800;
const bit<8>  PROTO_TCP = 6;
const bit<8>  PROTO_UDP = 17;
const bit<16> INT_MAGIC = 0x4954;

const bit<8> CH_UNKNOWN = 0;
#define NUM_CHANNELS 6
#define NUM_NODES    8

header ethernet_t { macAddr_t dstAddr; macAddr_t srcAddr; bit<16> etherType; }
header ipv4_t {
    bit<4> version; bit<4> ihl; bit<8> diffserv; bit<16> totalLen;
    bit<16> identification; bit<3> flags; bit<13> fragOffset;
    bit<8> ttl; bit<8> protocol; bit<16> hdrChecksum;
    ip4Addr_t srcAddr; ip4Addr_t dstAddr;
}
header tcp_t {
    bit<16> srcPort; bit<16> dstPort; bit<32> seqNo; bit<32> ackNo;
    bit<4> dataOffset; bit<4> res; bit<8> flags; bit<16> window;
    bit<16> checksum; bit<16> urgentPtr;
}
header udp_t { bit<16> srcPort; bit<16> dstPort; bit<16> length_; bit<16> checksum; }

header int_shim_t { bit<16> magic; bit<8> count; bit<8> rsvd; }

header int_meta_t {
    bit<8>  node_id;
    bit<8>  battery;
    bit<8>  cpu_load;
    bit<8>  queue_len;
    bit<48> ingress_ts;
}

struct headers_t {
    ethernet_t ethernet;
    ipv4_t     ipv4;
    tcp_t      tcp;
    udp_t      udp;
    int_shim_t int_shim;
    int_meta_t int_meta0;
    int_meta_t int_meta1;
}
struct metadata_t {
    bit<8> channel_id;
    bit<8> node_id;
    bit<1> int_on;
}
struct empty_t { }

#define INT_SHIM_B  4
#define INT_META_B  10

parser IngressParserImpl(packet_in pkt,
                         out headers_t hdr,
                         inout metadata_t meta,
                         in psa_ingress_parser_input_metadata_t istd,
                         in empty_t resub_meta,
                         in empty_t recirc_meta) {
    state start {
        meta.channel_id = CH_UNKNOWN;
        meta.node_id = 0;
        meta.int_on = 0;
        pkt.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default:   accept;
        }
    }
    state parse_ipv4 {
        pkt.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            PROTO_TCP: parse_tcp;
            PROTO_UDP: parse_udp;
            default:   accept;
        }
    }
    state parse_tcp { pkt.extract(hdr.tcp); transition accept; }
    state parse_udp {
        pkt.extract(hdr.udp);
        transition select(hdr.udp.dstPort) {
            5003:    pre_int;
            default: accept;
        }
    }

    state pre_int {
        transition select(pkt.lookahead<int_shim_t>().magic) {
            INT_MAGIC: parse_shim;
            default:   accept;
        }
    }
    state parse_shim {
        pkt.extract(hdr.int_shim);
        transition select(hdr.int_shim.count) {
            0:       accept;
            default: parse_m0;
        }
    }
    state parse_m0 {
        pkt.extract(hdr.int_meta0);
        transition select(hdr.int_shim.count) {
            1:       accept;
            default: parse_m1;
        }
    }
    state parse_m1 {
        pkt.extract(hdr.int_meta1);
        transition accept;
    }
}

control ingress(inout headers_t hdr,
                inout metadata_t meta,
                in    psa_ingress_input_metadata_t  istd,
                inout psa_ingress_output_metadata_t ostd) {

    Counter<bit<32>, bit<8>>(NUM_CHANNELS, PSA_CounterType_t.PACKETS) channel_ctr;

    Register<bit<32>, bit<32>>(NUM_NODES) battery_reg;
    Register<bit<32>, bit<32>>(NUM_NODES) cpu_reg;
    Register<bit<32>, bit<32>>(NUM_NODES) queue_reg;

    action ipv4_forward(PortId_t port) { send_to_port(ostd, port); }
    action drop() { ingress_drop(ostd); }
    action set_channel(bit<8> ch) { meta.channel_id = ch; }
    action set_node(bit<8> id) { meta.node_id = id; }
    action int_enable() { meta.int_on = 1; }
    action redirect_to_tn(PortId_t port) { send_to_port(ostd, port); }

    table ipv4_lpm {
        key = { hdr.ipv4.dstAddr : lpm; }
        actions = { ipv4_forward; drop; NoAction; }
        size = 1024; default_action = drop();
    }
    table channel_classify_tcp {
        key = { hdr.tcp.dstPort : exact; }
        actions = { set_channel; NoAction; } size = 64; default_action = NoAction();
    }
    table channel_classify_tcp_src {
        key = { hdr.tcp.srcPort : exact; }
        actions = { set_channel; NoAction; } size = 64; default_action = NoAction();
    }
    table channel_classify_udp {
        key = { hdr.udp.dstPort : exact; }
        actions = { set_channel; NoAction; } size = 64; default_action = NoAction();
    }
    table channel_classify_udp_src {
        key = { hdr.udp.srcPort : exact; }
        actions = { set_channel; NoAction; } size = 64; default_action = NoAction();
    }

    table node_map {
        key = { istd.ingress_port : exact; }
        actions = { set_node; NoAction; } size = 32; default_action = NoAction();
    }
    table int_config {
        key = { hdr.udp.dstPort : exact; }
        actions = { int_enable; NoAction; } size = 16; default_action = NoAction();
    }
    table mtd_redirect {
        key = { istd.ingress_port : exact; meta.channel_id : exact; }
        actions = { redirect_to_tn; NoAction; } size = 32; default_action = NoAction();
    }

    apply {
        if (hdr.ipv4.isValid()) {
            if (hdr.tcp.isValid()) {
                if (!channel_classify_tcp.apply().hit) { channel_classify_tcp_src.apply(); }
            } else if (hdr.udp.isValid()) {
                if (!channel_classify_udp.apply().hit) { channel_classify_udp_src.apply(); }
            }
            channel_ctr.count(meta.channel_id);

            node_map.apply();
            ipv4_lpm.apply();
            mtd_redirect.apply();

            if (hdr.udp.isValid()) {
                int_config.apply();
                if (meta.int_on == 1) {
                    bit<32> nidx = (bit<32>)meta.node_id;
                    bit<8> bat = (bit<8>) battery_reg.read(nidx);
                    bit<8> cpu = (bit<8>) cpu_reg.read(nidx);
                    bit<8> que = (bit<8>) queue_reg.read(nidx);
                    bit<48> ts = (bit<48>)(TimestampUint_t)istd.ingress_timestamp;

                    if (!hdr.int_shim.isValid()) {
                        hdr.int_shim.setValid();
                        hdr.int_shim.magic = INT_MAGIC;
                        hdr.int_shim.count = 1;
                        hdr.int_shim.rsvd  = 0;
                        hdr.int_meta0.setValid();
                        hdr.int_meta0.node_id    = meta.node_id;
                        hdr.int_meta0.battery    = bat;
                        hdr.int_meta0.cpu_load   = cpu;
                        hdr.int_meta0.queue_len  = que;
                        hdr.int_meta0.ingress_ts = ts;
                        hdr.ipv4.totalLen = hdr.ipv4.totalLen + INT_SHIM_B + INT_META_B;
                        hdr.udp.length_   = hdr.udp.length_   + INT_SHIM_B + INT_META_B;
                    } else if (hdr.int_shim.count == 1) {
                        hdr.int_shim.count = 2;
                        hdr.int_meta1.setValid();
                        hdr.int_meta1.node_id    = meta.node_id;
                        hdr.int_meta1.battery    = bat;
                        hdr.int_meta1.cpu_load   = cpu;
                        hdr.int_meta1.queue_len  = que;
                        hdr.int_meta1.ingress_ts = ts;
                        hdr.ipv4.totalLen = hdr.ipv4.totalLen + INT_META_B;
                        hdr.udp.length_   = hdr.udp.length_   + INT_META_B;
                    }
                    hdr.udp.checksum = 0;
                }
            }
        }
    }
}

control IngressDeparserImpl(packet_out pkt,
                            out empty_t clone_i2e_meta,
                            out empty_t resubmit_meta,
                            out empty_t normal_meta,
                            inout headers_t hdr,
                            in metadata_t meta,
                            in psa_ingress_output_metadata_t istd) {
    InternetChecksum() ck;
    apply {
        if (hdr.ipv4.isValid()) {
            ck.clear();
            ck.add({
                hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv,
                hdr.ipv4.totalLen, hdr.ipv4.identification,
                hdr.ipv4.flags, hdr.ipv4.fragOffset,
                hdr.ipv4.ttl, hdr.ipv4.protocol,
                hdr.ipv4.srcAddr, hdr.ipv4.dstAddr
            });
            hdr.ipv4.hdrChecksum = ck.get();
        }
        pkt.emit(hdr.ethernet);
        pkt.emit(hdr.ipv4);
        pkt.emit(hdr.tcp);
        pkt.emit(hdr.udp);
        pkt.emit(hdr.int_shim);
        pkt.emit(hdr.int_meta0);
        pkt.emit(hdr.int_meta1);
    }
}

parser EgressParserImpl(packet_in pkt, out headers_t hdr, inout metadata_t meta,
                        in psa_egress_parser_input_metadata_t istd,
                        in empty_t a, in empty_t b, in empty_t c) {
    state start { transition accept; }
}
control egress(inout headers_t hdr, inout metadata_t meta,
               in psa_egress_input_metadata_t istd,
               inout psa_egress_output_metadata_t ostd) { apply { } }
control EgressDeparserImpl(packet_out pkt, out empty_t a, out empty_t b,
                           inout headers_t hdr, in metadata_t meta,
                           in psa_egress_output_metadata_t istd,
                           in psa_egress_deparser_input_metadata_t edstd) {
    apply {
        pkt.emit(hdr.ethernet); pkt.emit(hdr.ipv4);
        pkt.emit(hdr.tcp); pkt.emit(hdr.udp);
        pkt.emit(hdr.int_shim); pkt.emit(hdr.int_meta0); pkt.emit(hdr.int_meta1);
    }
}

IngressPipeline(IngressParserImpl(), ingress(), IngressDeparserImpl()) ip;
EgressPipeline(EgressParserImpl(), egress(), EgressDeparserImpl()) ep;
PSA_Switch(ip, PacketReplicationEngine(), ep, BufferingQueueingEngine()) main;
