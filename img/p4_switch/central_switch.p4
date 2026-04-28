#include <core.p4>
#include <v1model.p4>

const bit<16> ETH_TYPE_IPV4 = 0x0800;
const bit<16> ETH_TYPE_ARP  = 0x0806;
const bit<8>  IP_PROTO_UDP  = 17;
const bit<16> UDP_PORT_GENEVE = 6081;

const bit<32> TLV_HOSTS  = 0x00000000;
const bit<32> TLV_PHONES = 0x00000001;
const bit<32> TLV_ARP    = 0x00000002;

header ethernet_t { bit<48> dstAddr; bit<48> srcAddr; bit<16> etherType; }
header ipv4_t {
    bit<4> version; bit<4> ihl; bit<8> diffserv; bit<16> totalLen;
    bit<16> identification; bit<3> flags; bit<13> fragOffset;
    bit<8> ttl; bit<8> protocol; bit<16> hdrChecksum;
    bit<32> srcAddr; bit<32> dstAddr;
}
header udp_t { bit<16> srcPort; bit<16> dstPort; bit<16> length; bit<16> checksum; }
header geneve_t {
    bit<2> version; bit<6> optionLen; bit<1> oam; bit<1> critical; bit<6> reserved0;
    bit<16> protocolType; bit<24> vni; bit<8> reserved1;
}
header geneve_opt_t {
    bit<16> optionClass; bit<8> type; bit<3> reserved; bit<5> length; bit<32> value;
}
header inner_ethernet_t { bit<48> dstAddr; bit<48> srcAddr; bit<16> etherType; }
header inner_ipv4_t {
    bit<4> version; bit<4> ihl; bit<8> diffserv; bit<16> totalLen;
    bit<16> identification; bit<3> flags; bit<13> fragOffset;
    bit<8> ttl; bit<8> protocol; bit<16> hdrChecksum;
    bit<32> srcAddr; bit<32> dstAddr;
}
header inner_arp_t {
    bit<16> htype; bit<16> ptype; bit<8> hlen; bit<8> plen; bit<16> oper;
    bit<48> sha; bit<32> spa; bit<48> tha; bit<32> tpa;
}

struct metadata_t { }
struct headers_t {
    ethernet_t ethernet;
    ipv4_t ipv4;
    udp_t udp;
    geneve_t geneve;
    geneve_opt_t geneve_opt;
    inner_ethernet_t inner_ethernet;
    inner_ipv4_t inner_ipv4;
    inner_arp_t inner_arp;
}

parser MyParser(packet_in packet,
                out headers_t hdr,
                inout metadata_t meta,
                inout standard_metadata_t standard_metadata) {
    state start {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) { ETH_TYPE_IPV4: parse_ipv4; default: accept; }
    }
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) { IP_PROTO_UDP: parse_udp; default: accept; }
    }
    state parse_udp {
        packet.extract(hdr.udp);
        transition select(hdr.udp.dstPort) { UDP_PORT_GENEVE: parse_geneve; default: accept; }
    }
    state parse_geneve { packet.extract(hdr.geneve); transition parse_geneve_opt; }
    state parse_geneve_opt { packet.extract(hdr.geneve_opt); transition parse_inner_ethernet; }
    state parse_inner_ethernet {
        packet.extract(hdr.inner_ethernet);
        transition select(hdr.inner_ethernet.etherType) {
            ETH_TYPE_IPV4: parse_inner_ipv4;
            ETH_TYPE_ARP: parse_inner_arp;
            default: accept;
        }
    }
    state parse_inner_ipv4 { packet.extract(hdr.inner_ipv4); transition accept; }
    state parse_inner_arp { packet.extract(hdr.inner_arp); transition accept; }
}

control MyVerifyChecksum(inout headers_t hdr, inout metadata_t meta) { apply { } }

control MyIngress(inout headers_t hdr,
                  inout metadata_t meta,
                  inout standard_metadata_t standard_metadata) {
    action drop() { mark_to_drop(standard_metadata); }

    action rewrite_and_forward(bit<9> port,
                               bit<48> src_mac,
                               bit<48> dst_mac,
                               bit<32> src_ip,
                               bit<32> dst_ip) {
        hdr.ethernet.srcAddr = src_mac;
        hdr.ethernet.dstAddr = dst_mac;
        hdr.ipv4.srcAddr = src_ip;
        hdr.ipv4.dstAddr = dst_ip;
        standard_metadata.egress_spec = port;
    }

    table forward_geneve_from_access {
        key = {
            hdr.geneve_opt.value: ternary;
            standard_metadata.ingress_port: exact;
        }
        actions = { rewrite_and_forward; drop; NoAction; }
        size = 16;
        default_action = drop();
    }

    table forward_geneve_to_access {
        key = { standard_metadata.ingress_port: exact; }
        actions = { rewrite_and_forward; drop; NoAction; }
        size = 8;
        default_action = drop();
    }

    apply {
        if (!hdr.geneve.isValid()) {
            drop();
        } else if (standard_metadata.ingress_port == 0) {
            forward_geneve_from_access.apply();
        } else {
            forward_geneve_to_access.apply();
        }
    }
}

control MyEgress(inout headers_t hdr,
                 inout metadata_t meta,
                 inout standard_metadata_t standard_metadata) { apply { } }

control MyComputeChecksum(inout headers_t hdr, inout metadata_t meta) {
    apply {
        update_checksum(
            hdr.ipv4.isValid(),
            { hdr.ipv4.version, hdr.ipv4.ihl, hdr.ipv4.diffserv, hdr.ipv4.totalLen,
              hdr.ipv4.identification, hdr.ipv4.flags, hdr.ipv4.fragOffset,
              hdr.ipv4.ttl, hdr.ipv4.protocol, hdr.ipv4.srcAddr, hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

control MyDeparser(packet_out packet, in headers_t hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.udp);
        packet.emit(hdr.geneve);
        packet.emit(hdr.geneve_opt);
        packet.emit(hdr.inner_ethernet);
        packet.emit(hdr.inner_ipv4);
        packet.emit(hdr.inner_arp);
    }
}

V1Switch(MyParser(), MyVerifyChecksum(), MyIngress(), MyEgress(), MyComputeChecksum(), MyDeparser()) main;
