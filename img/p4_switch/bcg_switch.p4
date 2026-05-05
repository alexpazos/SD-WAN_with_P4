#include <core.p4>
#include <v1model.p4>

const bit<16> ETH_TYPE_IPV4 = 0x0800;
const bit<16> ETH_TYPE_ARP  = 0x0806;
const bit<8>  IP_PROTO_UDP  = 17;
const bit<16> UDP_PORT_GENEVE = 6081;

const bit<32> TLV_HOSTS  = 0x00000000;
const bit<32> TLV_PHONES = 0x00000001;
const bit<32> TLV_ARP      = 0x00000002;
const bit<32> TLV_INTERNET = 0x00000003;

header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    bit<32> srcAddr;
    bit<32> dstAddr;
}

header udp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<16> length;
    bit<16> checksum;
}

header geneve_t {
    bit<2>  version;
    bit<6>  optionLen;
    bit<1>  oam;
    bit<1>  critical;
    bit<6>  reserved0;
    bit<16> protocolType;
    bit<24> vni;
    bit<8>  reserved1;
}

/* One 8-byte Geneve option: 4-byte option header + 4-byte value. */
header geneve_opt_t {
    bit<16> optionClass;
    bit<8>  type;
    bit<3>  reserved;
    bit<5>  length;
    bit<32> value;
}

header arp_t {
    bit<16> htype;
    bit<16> ptype;
    bit<8>  hlen;
    bit<8>  plen;
    bit<16> oper;
    bit<48> sha;
    bit<32> spa;
    bit<48> tha;
    bit<32> tpa;
}

struct metadata_t { }

struct headers_t {
    ethernet_t ethernet;
    ipv4_t     ipv4;
    udp_t      udp;
    geneve_t   geneve;
    geneve_opt_t geneve_opt;
    ethernet_t inner_ethernet;
    ipv4_t     inner_ipv4;
    arp_t      arp;
    arp_t      inner_arp;
}

parser MyParser(packet_in packet,
                out headers_t hdr,
                inout metadata_t meta,
                inout standard_metadata_t standard_metadata) {
    state start {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            ETH_TYPE_IPV4: parse_ipv4;
            ETH_TYPE_ARP:  parse_arp;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            IP_PROTO_UDP: parse_udp;
            default: accept;
        }
    }

    state parse_udp {
        packet.extract(hdr.udp);
        transition select(hdr.udp.dstPort) {
            UDP_PORT_GENEVE: parse_geneve;
            default: accept;
        }
    }

    state parse_geneve {
        packet.extract(hdr.geneve);
        transition parse_geneve_opt;
    }

    state parse_geneve_opt {
        packet.extract(hdr.geneve_opt);
        transition parse_inner_ethernet;
    }

    state parse_inner_ethernet {
        packet.extract(hdr.inner_ethernet);
        transition select(hdr.inner_ethernet.etherType) {
            ETH_TYPE_IPV4: parse_inner_ipv4;
            ETH_TYPE_ARP:  parse_inner_arp;
            default: accept;
        }
    }

    state parse_inner_ipv4 {
        packet.extract(hdr.inner_ipv4);
        transition accept;
    }

    state parse_arp {
        packet.extract(hdr.arp);
        transition accept;
    }

    state parse_inner_arp {
        packet.extract(hdr.inner_arp);
        transition accept;
    }
}

control MyVerifyChecksum(inout headers_t hdr, inout metadata_t meta) { apply { } }

control MyIngress(inout headers_t hdr,
                  inout metadata_t meta,
                  inout standard_metadata_t standard_metadata) {

    action drop() { mark_to_drop(standard_metadata); }

    action encap_geneve_ipv4(bit<9> port,
                             bit<48> outer_src_mac,
                             bit<48> outer_dst_mac,
                             bit<32> outer_src_ip,
                             bit<32> outer_dst_ip,
                             bit<24> vni,
                             bit<32> tlv_value) {
        bit<16> inner_len;

        inner_len = hdr.ipv4.totalLen + 14;

        hdr.inner_ethernet.setValid();
        hdr.inner_ethernet = hdr.ethernet;
        hdr.inner_ipv4.setValid();
        hdr.inner_ipv4 = hdr.ipv4;

        hdr.ethernet.srcAddr = outer_src_mac;
        hdr.ethernet.dstAddr = outer_dst_mac;
        hdr.ethernet.etherType = ETH_TYPE_IPV4;

        hdr.ipv4.version = 4;
        hdr.ipv4.ihl = 5;
        hdr.ipv4.diffserv = 0;
        hdr.ipv4.totalLen = inner_len + 20 + 8 + 8 + 8;
        hdr.ipv4.identification = 0;
        hdr.ipv4.flags = 0;
        hdr.ipv4.fragOffset = 0;
        hdr.ipv4.ttl = 64;
        hdr.ipv4.protocol = IP_PROTO_UDP;
        hdr.ipv4.srcAddr = outer_src_ip;
        hdr.ipv4.dstAddr = outer_dst_ip;

        hdr.udp.setValid();
        hdr.udp.srcPort = 49431;
        hdr.udp.dstPort = UDP_PORT_GENEVE;
        hdr.udp.length = inner_len + 8 + 8 + 8;
        hdr.udp.checksum = 0;

        hdr.geneve.setValid();
        hdr.geneve.version = 0;
        hdr.geneve.optionLen = 2;
        hdr.geneve.oam = 0;
        hdr.geneve.critical = 0;
        hdr.geneve.reserved0 = 0;
        hdr.geneve.protocolType = 0x6558;
        hdr.geneve.vni = vni;
        hdr.geneve.reserved1 = 0;

        hdr.geneve_opt.setValid();
        hdr.geneve_opt.optionClass = 0x0102;
        hdr.geneve_opt.type = 0x01;
        hdr.geneve_opt.reserved = 0;
        hdr.geneve_opt.length = 1;
        hdr.geneve_opt.value = tlv_value;

        standard_metadata.egress_spec = port;
    }

    action encap_geneve_arp(bit<9> port,
                            bit<48> outer_src_mac,
                            bit<48> outer_dst_mac,
                            bit<32> outer_src_ip,
                            bit<32> outer_dst_ip,
                            bit<24> vni,
                            bit<32> tlv_value) {
        bit<16> inner_len;

        inner_len = 42;

        hdr.inner_ethernet.setValid();
        hdr.inner_ethernet = hdr.ethernet;
        hdr.inner_arp.setValid();
        hdr.inner_arp = hdr.arp;
        hdr.arp.setInvalid();

        hdr.ethernet.srcAddr = outer_src_mac;
        hdr.ethernet.dstAddr = outer_dst_mac;
        hdr.ethernet.etherType = ETH_TYPE_IPV4;

        hdr.ipv4.setValid();
        hdr.ipv4.version = 4;
        hdr.ipv4.ihl = 5;
        hdr.ipv4.diffserv = 0;
        hdr.ipv4.totalLen = inner_len + 20 + 8 + 8 + 8;
        hdr.ipv4.identification = 0;
        hdr.ipv4.flags = 0;
        hdr.ipv4.fragOffset = 0;
        hdr.ipv4.ttl = 64;
        hdr.ipv4.protocol = IP_PROTO_UDP;
        hdr.ipv4.srcAddr = outer_src_ip;
        hdr.ipv4.dstAddr = outer_dst_ip;

        hdr.udp.setValid();
        hdr.udp.srcPort = 49431;
        hdr.udp.dstPort = UDP_PORT_GENEVE;
        hdr.udp.length = inner_len + 8 + 8 + 8;
        hdr.udp.checksum = 0;

        hdr.geneve.setValid();
        hdr.geneve.version = 0;
        hdr.geneve.optionLen = 2;
        hdr.geneve.oam = 0;
        hdr.geneve.critical = 0;
        hdr.geneve.reserved0 = 0;
        hdr.geneve.protocolType = 0x6558;
        hdr.geneve.vni = vni;
        hdr.geneve.reserved1 = 0;

        hdr.geneve_opt.setValid();
        hdr.geneve_opt.optionClass = 0x0102;
        hdr.geneve_opt.type = 0x01;
        hdr.geneve_opt.reserved = 0;
        hdr.geneve_opt.length = 1;
        hdr.geneve_opt.value = tlv_value;

        standard_metadata.egress_spec = port;
    }

    action decap_geneve_ipv4(bit<9> port) {
        hdr.ethernet = hdr.inner_ethernet;
        hdr.ipv4 = hdr.inner_ipv4;

        hdr.udp.setInvalid();
        hdr.geneve.setInvalid();
        hdr.geneve_opt.setInvalid();
        hdr.inner_ethernet.setInvalid();
        hdr.inner_ipv4.setInvalid();
        standard_metadata.egress_spec = port;
    }

    action decap_geneve_arp(bit<9> port) {
        hdr.ethernet = hdr.inner_ethernet;
        hdr.arp.setValid();
        hdr.arp = hdr.inner_arp;

        hdr.ipv4.setInvalid();
        hdr.udp.setInvalid();
        hdr.geneve.setInvalid();
        hdr.geneve_opt.setInvalid();
        hdr.inner_ethernet.setInvalid();
        hdr.inner_arp.setInvalid();
        standard_metadata.egress_spec = port;
    }

    table from_router_ipv4 {
        key = {
            hdr.ipv4.dstAddr: lpm;
            standard_metadata.ingress_port: exact;
        }
        actions = { encap_geneve_ipv4; drop; NoAction; }
        size = 32;
        default_action = drop();
    }

    table from_router_arp {
        key = { standard_metadata.ingress_port: exact; }
        actions = { encap_geneve_arp; drop; NoAction; }
        size = 4;
        default_action = drop();
    }

    table from_access_ipv4 {
        key = {
            hdr.geneve_opt.value: exact;
            standard_metadata.ingress_port: exact;
        }
        actions = { decap_geneve_ipv4; drop; NoAction; }
        size = 8;
        default_action = drop();
    }

    table from_access_arp {
        key = {
            hdr.geneve_opt.value: exact;
            standard_metadata.ingress_port: exact;
        }
        actions = { decap_geneve_arp; drop; NoAction; }
        size = 8;
        default_action = drop();
    }

    apply {
        if (standard_metadata.ingress_port == 0 || standard_metadata.ingress_port == 2) {
            if (hdr.arp.isValid()) {
                from_router_arp.apply();
            } else if (hdr.ipv4.isValid() && !hdr.geneve.isValid()) {
                from_router_ipv4.apply();
            } else {
                drop();
            }
        } else if (standard_metadata.ingress_port == 1 && hdr.geneve.isValid()) {
            if (hdr.inner_ipv4.isValid()) {
                from_access_ipv4.apply();
            } else if (hdr.inner_arp.isValid()) {
                from_access_arp.apply();
            } else {
                drop();
            }
        } else {
            drop();
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
            { hdr.ipv4.version,
              hdr.ipv4.ihl,
              hdr.ipv4.diffserv,
              hdr.ipv4.totalLen,
              hdr.ipv4.identification,
              hdr.ipv4.flags,
              hdr.ipv4.fragOffset,
              hdr.ipv4.ttl,
              hdr.ipv4.protocol,
              hdr.ipv4.srcAddr,
              hdr.ipv4.dstAddr },
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
        packet.emit(hdr.arp);
        packet.emit(hdr.inner_arp);
    }
}

V1Switch(MyParser(), MyVerifyChecksum(), MyIngress(), MyEgress(), MyComputeChecksum(), MyDeparser()) main;
