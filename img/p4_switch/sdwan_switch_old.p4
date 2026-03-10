/* 
 * Switch P4 SD-WAN - Programa básico
 * Funciones:
 * - Bridging L2 entre vxlan1 y p4s1-mpls
 * - Routing L3 para tráfico Internet vía vxlan2
 */

#include <core.p4>
#include <v1model.p4>

//==============================================================================
// HEADERS
//==============================================================================

typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;
typedef bit<9>  portId_t;

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

header arp_t {
    bit<16> hwType;
    bit<16> protoType;
    bit<8>  hwAddrLen;
    bit<8>  protoAddrLen;
    bit<16> opcode;
    macAddr_t senderHwAddr;
    ip4Addr_t senderProtoAddr;
    macAddr_t targetHwAddr;
    ip4Addr_t targetProtoAddr;
}

struct metadata {
    bit<1> l2_forward;  // 1 = L2 bridging, 0 = L3 routing
}

struct headers {
    ethernet_t ethernet;
    arp_t      arp;
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
        transition parse_ethernet;
    }
    
    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            0x0800: parse_ipv4;
            0x0806: parse_arp;
            default: accept;
        }
    }
    
    state parse_arp {
        packet.extract(hdr.arp);
        transition accept;
    }
    
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition accept;
    }
}

//==============================================================================
// CHECKSUM VERIFICATION
//==============================================================================

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply { }
}

//==============================================================================
// INGRESS PROCESSING
//==============================================================================

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {
    
    // Mapeo de puertos (debe coincidir con simple_switch)
    // Port 0: vxlan1 (VXLAN VNI 1 - WAN/MPLS)
    // Port 1: vxlan2 (VXLAN VNI 2 - Internet)
    // Port 2: p4s1-mpls (MPLS physical)
    // Port 3: p4s1-inet (Internet physical)
    // Port 4: p4s1-accessnet1 (Access to bcg)
    
    //==========================================================================
    // L2 FORWARDING TABLE (MAC learning)
    //==========================================================================
    
    action l2_forward(portId_t port) {
        standard_metadata.egress_spec = port;
    }
    
    action broadcast() {
        // Broadcast to all ports except ingress
        // En producción usar multicast groups
        standard_metadata.egress_spec = 511; // Drop for now
    }
    
    action drop() {
        mark_to_drop(standard_metadata);
    }
    
    table mac_learning {
        key = {
            hdr.ethernet.dstAddr: exact;
        }
        actions = {
            l2_forward;
            broadcast;
            drop;
        }
        size = 1024;
        default_action = broadcast();
    }
    
    //==========================================================================
    // PORT CLASSIFICATION
    //==========================================================================
    
    action set_l2_mode() {
        meta.l2_forward = 1;
    }
    
    action set_l3_mode() {
        meta.l2_forward = 0;
    }
    
    table port_classifier {
        key = {
            standard_metadata.ingress_port: exact;
        }
        actions = {
            set_l2_mode;
            set_l3_mode;
            NoAction;
        }
        size = 16;
        default_action = set_l2_mode();
    }
    
    //==========================================================================
    // L3 ROUTING TABLE
    //==========================================================================
    
    action ipv4_forward(macAddr_t dstAddr, portId_t port) {
        standard_metadata.egress_spec = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }
    
    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = drop();
    }
    
    //==========================================================================
    // APPLY LOGIC
    //==========================================================================
    
    apply {
        // Clasificar puerto (L2 o L3)
        port_classifier.apply();
        
        if (hdr.ethernet.isValid()) {
            
            // Modo L2: Bridging (vxlan1 ↔ p4s1-mpls)
            if (meta.l2_forward == 1) {
                
                // Si es ARP o tráfico L2, hacer bridging
                if (hdr.arp.isValid() || hdr.ipv4.isValid()) {
                    
                    // Forwarding L2 basado en MAC
                    if (mac_learning.apply().miss) {
                        // Si no conocemos la MAC, broadcast
                        broadcast();
                    }
                }
            }
            
            // Modo L3: Routing (vxlan2 → p4s1-inet)
            else if (hdr.ipv4.isValid()) {
                ipv4_lpm.apply();
            }
        }
    }
}

//==============================================================================
// EGRESS PROCESSING
//==============================================================================

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {
    apply { }
}

//==============================================================================
// CHECKSUM COMPUTATION
//==============================================================================

control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply {
        update_checksum(
            hdr.ipv4.isValid(),
            {
                hdr.ipv4.version,
                hdr.ipv4.ihl,
                hdr.ipv4.diffserv,
                hdr.ipv4.totalLen,
                hdr.ipv4.identification,
                hdr.ipv4.flags,
                hdr.ipv4.fragOffset,
                hdr.ipv4.ttl,
                hdr.ipv4.protocol,
                hdr.ipv4.srcAddr,
                hdr.ipv4.dstAddr
            },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16
        );
    }
}

//==============================================================================
// DEPARSER
//==============================================================================

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.arp);
        packet.emit(hdr.ipv4);
    }
}

//==============================================================================
// SWITCH
//==============================================================================

V1Switch(
    MyParser(),
    MyVerifyChecksum(),
    MyIngress(),
    MyEgress(),
    MyComputeChecksum(),
    MyDeparser()
) main;
