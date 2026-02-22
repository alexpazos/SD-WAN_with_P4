/* 
 * Switch P4 Simple - Bridging L2 puro
 * Lo que entra por port 0 sale por port 1, y viceversa
 */

#include <core.p4>
#include <v1model.p4>

//==============================================================================
// HEADERS
//==============================================================================

typedef bit<48> macAddr_t;
typedef bit<16> etherType_t;

header ethernet_t {
    macAddr_t   dstAddr;
    macAddr_t   srcAddr;
    etherType_t etherType;
}

struct metadata {
    /* Empty - no metadata needed */
}

struct headers {
    ethernet_t ethernet;
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
// INGRESS - LÓGICA PRINCIPAL
//==============================================================================

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {
    
    apply {
        // Lógica ultra-simple:
        // - Si entra por puerto 0 (vxlan1) → sale por puerto 1 (p4s1-mpls)
        // - Si entra por puerto 1 (p4s1-mpls) → sale por puerto 0 (vxlan1)
        
        if (standard_metadata.ingress_port == 0) {
            standard_metadata.egress_spec = 1;  // Port 0 → Port 1
        } else if (standard_metadata.ingress_port == 1) {
            standard_metadata.egress_spec = 0;  // Port 1 → Port 0
        } else {
            // Si llega por otro puerto, drop
            mark_to_drop(standard_metadata);
        }
    }
}

//==============================================================================
// EGRESS
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
    apply { }
}

//==============================================================================
// DEPARSER
//==============================================================================

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
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
