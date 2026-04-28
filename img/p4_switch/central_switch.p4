/* ============================================================
 * central_switch.p4  —  Switch P4 de la central de proximidad
 *
 * Ports:
 *   Port 0: p4cX-access   → AccessNet (BCG local)
 *   Port 1: p4cX-mpls     → MplsWan (teléfonos L2)
 *   Port 2: p4cX-tun-in   → veth → kernel → wg0 (cifrado hosts)
 *
 * Lógica:
 *   Port 0 entrada (Geneve+TLV): forward_geneve_from_access (ternary):
 *     bit0=0 (hosts)  → port 2 (kernel/wg0)  reescribe outer src/dst
 *     bit0=1 (phones) → port 1 (MplsWan)     reescribe outer src/dst
 *   Port 1 entrada (retorno MplsWan) → forward_geneve_to_access → port 0
 *   Port 2 entrada (retorno wg0)     → forward_geneve_to_access → port 0
 *
 * El paquete Geneve viaja intacto. Solo se reescribe outer IP src/dst.
 * ============================================================ */

#include <core.p4>
#include <v1model.p4>

const bit<16> ETHERTYPE_IPV4   = 0x0800;
const bit<16> ETHERTYPE_ARP    = 0x0806;
const bit<8>  IP_PROTO_UDP     = 17;
const bit<16> GENEVE_UDP_PORT  = 6081;
const bit<16> GENEVE_PROTO_IP  = 0x0800;
const bit<16> TLV_OPT_CLASS    = 0xFF01;
const bit<8>  TLV_TYPE         = 0x01;

header ethernet_t {
    bit<48> dst_addr;
    bit<48> src_addr;
    bit<16> ether_type;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> total_len;
    bit<16> identification;
    bit<3>  flags;
    bit<13> frag_offset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdr_checksum;
    bit<32> src_addr;
    bit<32> dst_addr;
}

header udp_t {
    bit<16> src_port;
    bit<16> dst_port;
    bit<16> length;
    bit<16> checksum;
}

header geneve_t {
    bit<2>  ver;
    bit<6>  opt_len;
    bit<1>  oam;
    bit<1>  critical;
    bit<6>  reserved;
    bit<16> protocol_type;
    bit<24> vni;
    bit<8>  reserved2;
}

header geneve_tlv_t {
    bit<16> option_class;
    bit<8>  opt_type;
    bit<3>  reserved;
    bit<5>  length;
    bit<32> data;
}

header arp_t {
    bit<16> hw_type;
    bit<16> proto_type;
    bit<8>  hw_size;
    bit<8>  proto_size;
    bit<16> opcode;
    bit<48> sender_mac;
    bit<32> sender_ip;
    bit<48> target_mac;
    bit<32> target_ip;
}

struct headers_t {
    ethernet_t    ethernet;
    ipv4_t        outer_ipv4;
    udp_t         udp;
    geneve_t      geneve;
    geneve_tlv_t  geneve_tlv;
    ipv4_t        inner_ipv4;
    arp_t         arp;
}

struct metadata_t {
    bit<1>  rewrite_macs;
    bit<48> new_src_mac;
    bit<48> new_dst_mac;
}

parser MyParser(packet_in pkt,
                out headers_t hdr,
                inout metadata_t meta,
                inout standard_metadata_t std_meta) {

    state start {
        meta.rewrite_macs = 0;
        meta.new_src_mac  = 0;
        meta.new_dst_mac  = 0;
        transition parse_ethernet;
    }

    state parse_ethernet {
        pkt.extract(hdr.ethernet);
        transition select(hdr.ethernet.ether_type) {
            ETHERTYPE_IPV4: parse_ipv4;
            ETHERTYPE_ARP:  parse_arp;
            default:        accept;
        }
    }

    state parse_arp { pkt.extract(hdr.arp); transition accept; }

    state parse_ipv4 {
        pkt.extract(hdr.outer_ipv4);
        transition select(hdr.outer_ipv4.protocol) {
            IP_PROTO_UDP: parse_udp;
            default:      accept;
        }
    }

    state parse_udp {
        pkt.extract(hdr.udp);
        transition select(hdr.udp.dst_port) {
            GENEVE_UDP_PORT: parse_geneve;
            default:         accept;
        }
    }

    state parse_geneve {
        pkt.extract(hdr.geneve);
        transition select(hdr.geneve.opt_len) {
            0:       parse_inner_ipv4;
            default: parse_geneve_tlv;
        }
    }

    state parse_geneve_tlv {
        pkt.extract(hdr.geneve_tlv);
        transition parse_inner_ipv4;
    }

    state parse_inner_ipv4 {
        pkt.extract(hdr.inner_ipv4);
        transition accept;
    }
}

control MyVerifyChecksum(inout headers_t hdr, inout metadata_t meta) {
    apply { }
}

control MyIngress(inout headers_t hdr,
                  inout metadata_t meta,
                  inout standard_metadata_t std_meta) {

    action drop() { mark_to_drop(std_meta); }

    action rewrite_and_forward(bit<9>  egress_port,
                               bit<48> new_src_mac,
                               bit<48> new_dst_mac,
                               bit<32> new_src_ip,
                               bit<32> new_dst_ip) {
        std_meta.egress_spec        = egress_port;
        hdr.outer_ipv4.src_addr     = new_src_ip;
        hdr.outer_ipv4.dst_addr     = new_dst_ip;
        hdr.outer_ipv4.hdr_checksum = 0;
        meta.rewrite_macs           = 1;
        meta.new_src_mac            = new_src_mac;
        meta.new_dst_mac            = new_dst_mac;
    }

    table forward_geneve_from_access {
        key = { hdr.geneve_tlv.data : ternary; }
        actions = { rewrite_and_forward; drop; }
        default_action = drop();
        size = 4;
    }

    table forward_geneve_to_access {
        key = { std_meta.ingress_port : exact; }
        actions = { rewrite_and_forward; drop; }
        default_action = drop();
        size = 4;
    }

    apply {
        if (std_meta.ingress_port == 0) {
            if (hdr.geneve.isValid()) {
                if (hdr.geneve_tlv.isValid() &&
                    hdr.geneve_tlv.option_class == TLV_OPT_CLASS &&
                    hdr.geneve_tlv.opt_type == TLV_TYPE) {
                    forward_geneve_from_access.apply();
                } else {
                    drop();
                }
            } else if (hdr.arp.isValid()) {
                std_meta.egress_spec = 1;
            } else {
                drop();
            }
        } else if (std_meta.ingress_port == 1 || std_meta.ingress_port == 2) {
            if (hdr.geneve.isValid()) {
                forward_geneve_to_access.apply();
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
                 inout standard_metadata_t std_meta) {
    apply {
        if (meta.rewrite_macs == 1) {
            hdr.ethernet.src_addr = meta.new_src_mac;
            hdr.ethernet.dst_addr = meta.new_dst_mac;
        }
    }
}

control MyComputeChecksum(inout headers_t hdr, inout metadata_t meta) {
    apply {
        update_checksum(
            hdr.outer_ipv4.isValid(),
            { hdr.outer_ipv4.version, hdr.outer_ipv4.ihl,
              hdr.outer_ipv4.diffserv, hdr.outer_ipv4.total_len,
              hdr.outer_ipv4.identification, hdr.outer_ipv4.flags,
              hdr.outer_ipv4.frag_offset, hdr.outer_ipv4.ttl,
              hdr.outer_ipv4.protocol,
              hdr.outer_ipv4.src_addr, hdr.outer_ipv4.dst_addr },
            hdr.outer_ipv4.hdr_checksum,
            HashAlgorithm.csum16
        );
    }
}

control MyDeparser(packet_out pkt, in headers_t hdr) {
    apply {
        pkt.emit(hdr.ethernet);
        pkt.emit(hdr.outer_ipv4);
        pkt.emit(hdr.udp);
        pkt.emit(hdr.geneve);
        pkt.emit(hdr.geneve_tlv);
        pkt.emit(hdr.inner_ipv4);
        pkt.emit(hdr.arp);
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
