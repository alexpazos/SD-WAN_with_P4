/* -*- P4_16 -*- */
#include <core.p4>
#include <v1model.p4>

typedef bit<9>  egressSpec_t;
typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;

/*************************************************************************
 * CONSTANTS
 *************************************************************************/

const bit<16> TYPE_IPV4 = 0x0800;
const bit<8>  PROTO_UDP = 17;
const bit<16> UDP_PORT_VXLAN_1 = 4789;  // VXLAN estándar
const bit<16> UDP_PORT_VXLAN_2 = 8742;  // VXLAN custom

/*************************************************************************
 * HEADERS
 *************************************************************************/

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

header udp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<16> length;
    bit<16> checksum;
}

header vxlan_t {
    bit<8>  flags;
    bit<24> reserved;
    bit<24> vni;           // VXLAN Network Identifier
    bit<8>  reserved2;
}

struct metadata {
    bit<2>  traffic_class;  // 0=local, 1=inter-sedes, 2=internet
    bit<24> vni;            // VXLAN ID extraído
    bit<1>  is_vxlan;       // Flag: es tráfico VXLAN
}

struct headers {
    ethernet_t   ethernet;
    ipv4_t       ipv4;
    udp_t        udp;
    vxlan_t      vxlan;
    // Headers internos (dentro del túnel VXLAN)
    ethernet_t   inner_ethernet;
    ipv4_t       inner_ipv4;
}

/*************************************************************************
 * PARSER
 *************************************************************************/

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        meta.traffic_class = 0;
        meta.is_vxlan = 0;
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            PROTO_UDP: parse_udp;
            default: accept;
        }
    }

    state parse_udp {
        packet.extract(hdr.udp);
        transition select(hdr.udp.dstPort) {
            UDP_PORT_VXLAN_1: parse_vxlan;
            UDP_PORT_VXLAN_2: parse_vxlan;
            default: accept;
        }
    }

    state parse_vxlan {
        packet.extract(hdr.vxlan);
        meta.vni = hdr.vxlan.vni;
        meta.is_vxlan = 1;
        
        // Extraer headers internos (el tráfico real del cliente)
        packet.extract(hdr.inner_ethernet);
        transition select(hdr.inner_ethernet.etherType) {
            TYPE_IPV4: parse_inner_ipv4;
            default: accept;
        }
    }

    state parse_inner_ipv4 {
        packet.extract(hdr.inner_ipv4);
        transition accept;
    }
}

/*************************************************************************
 * CHECKSUM VERIFICATION
 *************************************************************************/

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {  }
}

/*************************************************************************
 * INGRESS PROCESSING - AQUÍ ESTÁ LA LÓGICA PRINCIPAL
 *************************************************************************/

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    // Acción: Descartar paquete
    action drop() {
        mark_to_drop(standard_metadata);
    }

    // Acción: Reenviar a un puerto específico
    action forward(egressSpec_t port) {
        standard_metadata.egress_spec = port;
    }

    // Acción: Reenviar con actualización de MAC y TTL
    action ipv4_forward(macAddr_t dstAddr, egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        
        // Decrementar TTL del paquete interno (si es VXLAN)
        if (hdr.inner_ipv4.isValid()) {
            hdr.inner_ipv4.ttl = hdr.inner_ipv4.ttl - 1;
        } else if (hdr.ipv4.isValid()) {
            hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
        }
    }

    // Acción: Marcar tráfico como inter-sedes
    action set_inter_site() {
        meta.traffic_class = 1;
    }

    // Acción: Marcar tráfico como Internet
    action set_internet() {
        meta.traffic_class = 2;
    }

    /*
     * TABLA 1: Clasificar destino del tráfico
     * 
     * Pregunta: ¿A dónde va este paquete?
     * - Si destino es el otro site (10.20.X.0/24) → MPLS (inter-sedes)
     * - Si destino es Internet → ISP
     * - Default: drop
     */
    table destination_classifier {
        key = {
            // Usar la IP interna si es VXLAN, sino la externa
            hdr.inner_ipv4.dstAddr: lpm;
        }
        actions = {
            set_inter_site;
            set_internet;
            drop;
        }
        size = 1024;
        default_action = drop();
    }

    /*
     * TABLA 2: Forwarding por clasificación
     * 
     * Según traffic_class, reenviar al puerto correcto:
     * - traffic_class=1 (inter-sedes) → Puerto 2 (MPLS)
     * - traffic_class=2 (internet) → Puerto 3 (ISP)
     * - Default: devolver al cliente (puerto 1)
     */
    table traffic_forward {
        key = {
            meta.traffic_class: exact;
            standard_metadata.ingress_port: exact;
        }
        actions = {
            forward;
            drop;
        }
        size = 64;
        default_action = drop();
    }

    /*
     * TABLA 3: Forwarding IPv4 con LPM (opcional, para mayor control)
     * 
     * Routing tradicional basado en IP destino
     */
    table ipv4_lpm {
        key = {
            hdr.inner_ipv4.dstAddr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
        }
        size = 512;
        default_action = drop();
    }

    /*
     * APPLY: Lógica de procesamiento
     */
    apply {
        // Si es tráfico VXLAN del cliente
        if (meta.is_vxlan == 1 && hdr.inner_ipv4.isValid()) {
            
            // Paso 1: Clasificar destino
            destination_classifier.apply();
            
            // Paso 2: Reenviar según clasificación
            // Esto implementa la lógica que antes hacían ACCESS, CPE y WAN
            if (!traffic_forward.apply().hit) {
                // Si no hay regla de clasificación, intentar LPM
                ipv4_lpm.apply();
            }
            
        } else if (hdr.ipv4.isValid()) {
            // Tráfico no-VXLAN (por ejemplo, tráfico de retorno desde MPLS)
            
            // Si viene de MPLS (puerto 2), devolver al cliente
            if (standard_metadata.ingress_port == 2) {
                forward(1);  // Puerto 1 = vxlan1 (cliente)
            }
            // Si viene de Internet (puerto 3), devolver al cliente
            else if (standard_metadata.ingress_port == 3) {
                forward(1);
            }
        }
    }
}

/*************************************************************************
 * EGRESS PROCESSING
 *************************************************************************/

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {
    
    /*
     * Aquí se puede añadir:
     * - QoS (meters, queues)
     * - Reescritura de encapsulación VXLAN
     * - Estadísticas
     */
    
    apply {
        // Por ahora vacío, pero listo para extensiones
    }
}

/*************************************************************************
 * CHECKSUM COMPUTATION
 *************************************************************************/

control MyComputeChecksum(inout headers hdr, inout metadata meta) {
    apply {
        // Recalcular checksum del IP externo
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

        // Recalcular checksum del IP interno (dentro de VXLAN)
        update_checksum(
            hdr.inner_ipv4.isValid(),
            { 
                hdr.inner_ipv4.version,
                hdr.inner_ipv4.ihl,
                hdr.inner_ipv4.diffserv,
                hdr.inner_ipv4.totalLen,
                hdr.inner_ipv4.identification,
                hdr.inner_ipv4.flags,
                hdr.inner_ipv4.fragOffset,
                hdr.inner_ipv4.ttl,
                hdr.inner_ipv4.protocol,
                hdr.inner_ipv4.srcAddr,
                hdr.inner_ipv4.dstAddr 
            },
            hdr.inner_ipv4.hdrChecksum,
            HashAlgorithm.csum16
        );
    }
}

/*************************************************************************
 * DEPARSER - Reconstruir el paquete
 *************************************************************************/

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        // Emitir headers en orden
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.udp);
        packet.emit(hdr.vxlan);
        packet.emit(hdr.inner_ethernet);
        packet.emit(hdr.inner_ipv4);
    }
}

/*************************************************************************
 * SWITCH - Ensamblar el pipeline
 *************************************************************************/

V1Switch(
    MyParser(),
    MyVerifyChecksum(),
    MyIngress(),
    MyEgress(),
    MyComputeChecksum(),
    MyDeparser()
) main;
