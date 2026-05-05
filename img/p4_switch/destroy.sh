#!/usr/bin/env bash
#==============================================================================
# destroy_l2.sh - Destruir contenedores P4 L2 transparente
# No toca el escenario VNX ni ExtNet.
#==============================================================================

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'
print_info() { echo -e "${GREEN}[OK]${NC} $1"; }

echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}  SD-WAN P4 L2 - destruir contenedores${NC}"
echo -e "${CYAN}==========================================${NC}"

for c in p4-central-sede1 p4-central-sede2 p4-bcg-sede1 p4-bcg-sede2; do
    docker rm -f ${c} 2>/dev/null && print_info "Contenedor ${c} eliminado" || true
done

for port in p4c1-access p4c1-mpls p4c1-isp \
            p4c2-access p4c2-mpls p4c2-isp \
            p4bcg1-access p4bcg2-access; do
    ovs-vsctl --if-exists del-port ${port} 2>/dev/null || true
done
print_info "Puertos OVS eliminados"

for veth in veth-p4bcg1-rou veth-p4bcg2-rou veth-p4bcg1-cpe veth-p4bcg2-cpe \
            p4bcg1-router p4bcg2-router p4bcg1-cpe p4bcg2-cpe; do
    ip link del ${veth} 2>/dev/null || true
done
print_info "Veths Linux eliminados"

print_info "Destruccion completada. VNX sigue activo."
