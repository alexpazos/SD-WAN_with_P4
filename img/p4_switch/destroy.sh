#!/usr/bin/env bash
#==============================================================================
# destroy.sh — Destruir contenedores P4 (BCGs + Centrales)
# No toca el escenario VNX (hosts, routers)
#==============================================================================

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[✓]${NC} $1"; }

echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   SD-WAN P4 — Destruir contenedores  ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"

# Contenedores
for c in p4-central-sede1 p4-central-sede2 p4-bcg-sede1 p4-bcg-sede2; do
    docker rm -f ${c} 2>/dev/null && print_info "Contenedor ${c} eliminado" || true
done

# Puertos OVS
for port in p4c1-access p4c1-mpls p4c1-isp \
            p4c2-access p4c2-mpls p4c2-isp \
            p4bcg1-access p4bcg2-access; do
    ovs-vsctl --if-exists del-port ${port} 2>/dev/null || true
done
print_info "Puertos OVS eliminados"

# Veths del host (router-side y out-side de los BCGs)
for veth in veth-p4bcg1-rou veth-p4bcg2-rou \
            veth-p4bcg1-out veth-p4bcg2-out \
            p4bcg1-router p4bcg2-router \
            p4bcg1-out p4bcg2-out; do
    ip link del ${veth} 2>/dev/null || true
done
print_info "Veths Linux eliminados"

echo ""
print_info "Destrucción completada. VNX sigue activo."
