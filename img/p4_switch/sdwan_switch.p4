/*
 * Switch P4 SD-WAN
 * Port 0: vxlan1    → BCG
 * Port 1: p4sX-mpls → MPLS (teléfonos)
 * Port 2: p4sX-isp  → ExtNet (hosts)
 *
 * Lógica:
 *   Port 0 entrada, IP dst 10.20.x.128/25 → Port 1 (MPLS)
 *   Port 0 entrada, IP dst 10.20.x.0/25   → Port 2 (ISP)
 *   Port 0 entrada, ARP                   → Port 1 (MPLS)
 *   Port 1 entrada                        → Port 0 (BCG)
 *   Port 2 entrada                        → Port 0 (BCG)
 */

#include <core.p4>
#include <v1model.p4>

const bit<16> TYPE_IPV4 = 0x0800;
const bit<16> TYPE_ARP  = 0x0806;

typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;

header ethernet_t {
    macAddr_t   dstAddr;
    macAddr_t   srcAddr;
    bit<16>     etherType;
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

struct metadata { }

struct headers {
    ethernet_t ethernet;
    ipv4_t     ipv4;
}

//==============================================================================
// PARSER
//==============================================================================
parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {
    state start {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default:   accept;
        }
    }
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition accept;
    }
}

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

//==============================================================================
// INGRESS
//==============================================================================
control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    action drop() {
        mark_to_drop(standard_metadata);
    }

    action to_mpls() {
        standard_metadata.egress_spec = 1;
    }

    action to_isp() {
        standard_metadata.egress_spec = 2;
    }

    action to_bcg() {
        standard_metadata.egress_spec = 0;
    }

    table routing {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            to_mpls;
            to_isp;
            drop;
        }
        default_action = drop();
        size = 16;
    }

    apply {
        if (standard_metadata.ingress_port == 0) {
            if (hdr.ipv4.isValid()) {
                routing.apply();
            } else {
                // ARP u otro tráfico no-IP desde BCG → MPLS
                to_mpls();
            }
        } else if (standard_metadata.ingress_port == 1) {
            to_bcg();
        } else if (standard_metadata.ingress_port == 2) {
            to_bcg();
        } else {
            drop();
        }
    }
}

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {
    apply { }
}

control MyComputeChecksum(inout headers hdr, inout metadata meta) {
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
            HashAlgorithm.csum16
        );
    }
}

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
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