/* ============================================================
 * bcg_switch.p4  —  Switch P4 del BCG (sede remota)
 *
 * Ports:
 *   Port 0: p4bcgX-router  → lan11/lan21 (hacia router)
 *   Port 1: p4bcgX-access  → AccessNet (Geneve hacia central)
 *   Port 2: p4bcgX-tun-in  → veth interno → kernel → veth externo → lan11/lan21
 *                            (retorno desencapsulado, NO pasa por port 0)
 *
 * Lógica:
 *   Port 0 entrada (IP):
 *     dst 10.20.x.0/25   → encap Geneve TLV=hosts(0)  → port 1
 *     dst 10.20.x.128/25 → encap Geneve TLV=phones(1) → port 1
 *   Port 0 entrada (ARP) → port 1
 *   Port 1 entrada (Geneve) → decap → port 2 (kernel)
 *   Port 1 entrada (ARP)    → port 0
 *
 * Inner del Geneve es IP puro (no Ethernet).
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
const bit<5>  TLV_LENGTH       = 1;

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
    bit<1>  do_encap;
    bit<1>  do_decap;
    bit<48> tunnel_src_mac;
    bit<48> tunnel_dst_mac;
    bit<32> tunnel_src_ip;
    bit<32> tunnel_dst_ip;
    bit<24> vni;
    bit<32> tlv_data;
}

parser MyParser(packet_in pkt,
                out headers_t hdr,
                inout metadata_t meta,
                inout standard_metadata_t std_meta) {

    state start {
        meta.do_encap       = 0;
        meta.do_decap       = 0;
        meta.tunnel_src_mac = 0;
        meta.tunnel_dst_mac = 0;
        meta.tlv_data       = 0;
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

    action forward(bit<9> egress_port) {
        std_meta.egress_spec = egress_port;
    }

    action encap_geneve_tlv(bit<9>  egress_port,
                            bit<48> src_mac,
                            bit<48> dst_mac,
                            bit<32> src_ip,
                            bit<32> dst_ip,
                            bit<24> vni,
                            bit<32> tlv_data) {
        std_meta.egress_spec = egress_port;
        meta.do_encap        = 1;
        meta.tunnel_src_mac  = src_mac;
        meta.tunnel_dst_mac  = dst_mac;
        meta.tunnel_src_ip   = src_ip;
        meta.tunnel_dst_ip   = dst_ip;
        meta.vni             = vni;
        meta.tlv_data        = tlv_data;
    }

    // tun_src_mac: MAC del extremo P4 (tun-in)
    // tun_dst_mac: MAC del extremo kernel (tun-out)
    action decap_geneve(bit<9>  egress_port,
                        bit<48> tun_src_mac,
                        bit<48> tun_dst_mac) {
        std_meta.egress_spec = egress_port;
        meta.do_decap        = 1;
        meta.tunnel_src_mac  = tun_src_mac;
        meta.tunnel_dst_mac  = tun_dst_mac;
    }

    table from_router {
        key = {
            hdr.outer_ipv4.dst_addr : lpm;
            std_meta.ingress_port   : exact;
        }
        actions = { encap_geneve_tlv; drop; }
        default_action = drop();
        size = 64;
    }

    table from_access {
        key = {
            hdr.inner_ipv4.dst_addr : lpm;
            std_meta.ingress_port   : exact;
        }
        actions = { decap_geneve; drop; }
        default_action = drop();
        size = 64;
    }

    apply {
        if (std_meta.ingress_port == 0) {
            if (hdr.arp.isValid()) {
                forward(1);
            } else if (hdr.outer_ipv4.isValid()) {
                from_router.apply();
            } else {
                drop();
            }
        } else if (std_meta.ingress_port == 1) {
            if (hdr.geneve.isValid()) {
                from_access.apply();
            } else if (hdr.arp.isValid()) {
                forward(0);
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

        if (meta.do_encap == 1) {
            // El IP del router pasa a ser inner
            hdr.inner_ipv4.setValid();
            hdr.inner_ipv4.version        = hdr.outer_ipv4.version;
            hdr.inner_ipv4.ihl            = hdr.outer_ipv4.ihl;
            hdr.inner_ipv4.diffserv       = hdr.outer_ipv4.diffserv;
            hdr.inner_ipv4.total_len      = hdr.outer_ipv4.total_len;
            hdr.inner_ipv4.identification = hdr.outer_ipv4.identification;
            hdr.inner_ipv4.flags          = hdr.outer_ipv4.flags;
            hdr.inner_ipv4.frag_offset    = hdr.outer_ipv4.frag_offset;
            hdr.inner_ipv4.ttl            = hdr.outer_ipv4.ttl - 1;
            hdr.inner_ipv4.protocol       = hdr.outer_ipv4.protocol;
            hdr.inner_ipv4.hdr_checksum   = 0;
            hdr.inner_ipv4.src_addr       = hdr.outer_ipv4.src_addr;
            hdr.inner_ipv4.dst_addr       = hdr.outer_ipv4.dst_addr;

            hdr.geneve_tlv.setValid();
            hdr.geneve_tlv.option_class = TLV_OPT_CLASS;
            hdr.geneve_tlv.opt_type     = TLV_TYPE;
            hdr.geneve_tlv.reserved     = 0;
            hdr.geneve_tlv.length       = TLV_LENGTH;
            hdr.geneve_tlv.data         = meta.tlv_data;

            hdr.geneve.setValid();
            hdr.geneve.ver           = 0;
            hdr.geneve.opt_len       = 2;
            hdr.geneve.oam           = 0;
            hdr.geneve.critical      = 0;
            hdr.geneve.reserved      = 0;
            hdr.geneve.protocol_type = GENEVE_PROTO_IP;
            hdr.geneve.vni           = meta.vni;
            hdr.geneve.reserved2     = 0;

            hdr.udp.setValid();
            hdr.udp.src_port = 0xC117;
            hdr.udp.dst_port = GENEVE_UDP_PORT;
            hdr.udp.length   = 8 + 8 + 8 + hdr.inner_ipv4.total_len;
            hdr.udp.checksum = 0;

            hdr.outer_ipv4.setValid();
            hdr.outer_ipv4.version        = 4;
            hdr.outer_ipv4.ihl            = 5;
            hdr.outer_ipv4.diffserv       = 0;
            hdr.outer_ipv4.total_len      = 20 + hdr.udp.length;
            hdr.outer_ipv4.identification = 0;
            hdr.outer_ipv4.flags          = 0;
            hdr.outer_ipv4.frag_offset    = 0;
            hdr.outer_ipv4.ttl            = 64;
            hdr.outer_ipv4.protocol       = IP_PROTO_UDP;
            hdr.outer_ipv4.hdr_checksum   = 0;
            hdr.outer_ipv4.src_addr       = meta.tunnel_src_ip;
            hdr.outer_ipv4.dst_addr       = meta.tunnel_dst_ip;

            hdr.ethernet.dst_addr   = meta.tunnel_dst_mac;
            hdr.ethernet.src_addr   = meta.tunnel_src_mac;
            hdr.ethernet.ether_type = ETHERTYPE_IPV4;

        } else if (meta.do_decap == 1) {
            // Emitir hacia el kernel (port 2 = tun-in)
            // dst_mac = MAC de tun-out (para que el kernel acepte el paquete)
            // src_mac = MAC de tun-in
            hdr.ethernet.dst_addr   = meta.tunnel_dst_mac;
            hdr.ethernet.src_addr   = meta.tunnel_src_mac;
            hdr.ethernet.ether_type = ETHERTYPE_IPV4;

            hdr.outer_ipv4.setInvalid();
            hdr.udp.setInvalid();
            hdr.geneve.setInvalid();
            hdr.geneve_tlv.setInvalid();
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
        update_checksum(
            hdr.inner_ipv4.isValid(),
            { hdr.inner_ipv4.version, hdr.inner_ipv4.ihl,
              hdr.inner_ipv4.diffserv, hdr.inner_ipv4.total_len,
              hdr.inner_ipv4.identification, hdr.inner_ipv4.flags,
              hdr.inner_ipv4.frag_offset, hdr.inner_ipv4.ttl,
              hdr.inner_ipv4.protocol,
              hdr.inner_ipv4.src_addr, hdr.inner_ipv4.dst_addr },
            hdr.inner_ipv4.hdr_checksum,
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
