#!/usr/bin/env bash
#==============================================================================
# Script maestro - Despliegue completo de ambas sedes
#==============================================================================
set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_banner() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║     DESPLIEGUE SWITCHES P4 SD-WAN - CONSOLIDADOS              ║
║     Cada switch = VNF Access + VNF WAN + VNF CPE              ║
║                                                                ║
║     • 2 Sedes con 5 interfaces cada una                       ║
║     • VXLAN tunnels (VNI 1, 2)                                ║
║     • MPLS + Internet + NAT                                   ║
║     • Opcional: Programa P4 para L2 bridging                  ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}\n"
}

check_scripts() {
    if [ ! -f "$SCRIPT_DIR/deploy_p4_switch_sede1.sh" ]; then
        echo -e "${RED}[✗]${NC} Falta: deploy_p4_switch_sede1.sh"
        exit 1
    fi
    
    if [ ! -f "$SCRIPT_DIR/deploy_p4_switch_sede2.sh" ]; then
        echo -e "${RED}[✗]${NC} Falta: deploy_p4_switch_sede2.sh"
        exit 1
    fi
    
    chmod +x "$SCRIPT_DIR/deploy_p4_switch_sede1.sh"
    chmod +x "$SCRIPT_DIR/deploy_p4_switch_sede2.sh"
    
    echo -e "${GREEN}[✓]${NC} Scripts encontrados"
    
    # Verificar si hay programa P4
    if [ -n "$P4_CONFIG" ] && [ -f "$P4_CONFIG" ]; then
        echo -e "${GREEN}[✓]${NC} Programa P4 detectado: $P4_CONFIG"
        echo -e "${CYAN}    Los switches se desplegarán con simple_switch${NC}"
    else
        echo -e "${YELLOW}[!]${NC} Sin programa P4 (variable P4_CONFIG no definida)"
        echo -e "${CYAN}    Los switches usarán forwarding Linux${NC}"
    fi
    echo ""
}

deploy_sede1() {
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  DESPLEGANDO SEDE 1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}\n"
    
    "$SCRIPT_DIR/deploy_p4_switch_sede1.sh"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}[✗]${NC} Error al desplegar Sede 1"
        exit 1
    fi
}

deploy_sede2() {
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  DESPLEGANDO SEDE 2${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}\n"
    
    "$SCRIPT_DIR/deploy_p4_switch_sede2.sh"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}[✗]${NC} Error al desplegar Sede 2"
        exit 1
    fi
}

test_connectivity() {
    echo -e "\n${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  TESTS DE CONECTIVIDAD${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}\n"
    
    echo "Test 1: Sede 1 → Sede 2 (MPLS)"
    if docker exec p4-switch-sede1 ping -c 2 -W 2 10.20.0.12 &> /dev/null; then
        echo -e "${GREEN}[✓]${NC} Sede 1 alcanza Sede 2 via MPLS (10.20.0.12)"
    else
        echo -e "${YELLOW}[!]${NC} Sede 1 no alcanza Sede 2 via MPLS"
    fi
    
    echo ""
    echo "Test 2: Sede 2 → Sede 1 (MPLS)"
    if docker exec p4-switch-sede2 ping -c 2 -W 2 10.20.0.11 &> /dev/null; then
        echo -e "${GREEN}[✓]${NC} Sede 2 alcanza Sede 1 via MPLS (10.20.0.11)"
    else
        echo -e "${YELLOW}[!]${NC} Sede 2 no alcanza Sede 1 via MPLS"
    fi
    
    echo ""
    echo "Test 3: Sede 1 → bcg1 (VXLAN)"
    if docker exec p4-switch-sede1 ping -c 2 -W 2 10.255.0.2 &> /dev/null; then
        echo -e "${GREEN}[✓]${NC} Sede 1 alcanza bcg1 (10.255.0.2)"
    else
        echo -e "${YELLOW}[!]${NC} Sede 1 no alcanza bcg1 (verificar VNX)"
    fi
    
    echo ""
    echo "Test 4: Sede 2 → bcg2 (VXLAN)"
    if docker exec p4-switch-sede2 ping -c 2 -W 2 10.255.0.2 &> /dev/null; then
        echo -e "${GREEN}[✓]${NC} Sede 2 alcanza bcg2 (10.255.0.2)"
    else
        echo -e "${YELLOW}[!]${NC} Sede 2 no alcanza bcg2 (verificar VNX)"
    fi
    
    echo ""
    echo "Test 5: Sede 1 → ISP1"
    if docker exec p4-switch-sede1 ping -c 2 -W 2 10.100.1.254 &> /dev/null; then
        echo -e "${GREEN}[✓]${NC} Sede 1 alcanza ISP1 (10.100.1.254)"
    else
        echo -e "${YELLOW}[!]${NC} Sede 1 no alcanza ISP1 (verificar Containerlab)"
    fi
    
    echo ""
    echo "Test 6: Sede 2 → ISP2"
    if docker exec p4-switch-sede2 ping -c 2 -W 2 10.100.2.254 &> /dev/null; then
        echo -e "${GREEN}[✓]${NC} Sede 2 alcanza ISP2 (10.100.2.254)"
    else
        echo -e "${YELLOW}[!]${NC} Sede 2 no alcanza ISP2 (verificar Containerlab)"
    fi
}

show_summary() {
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  RESUMEN DEL DESPLIEGUE"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n"
    
    echo "═══════════════════════════════════════════════════════════"
    echo "  SEDE 1"
    echo "═══════════════════════════════════════════════════════════"
    echo "  Contenedor:  p4-switch-sede1"
    echo "  Gestión:     172.16.0.11"
    echo "  Thrift:      9091"
    echo ""
    docker exec p4-switch-sede1 ip -br addr 2>/dev/null | grep -v "lo\|eth0" | head -5 || true
    echo ""
    
    echo "═══════════════════════════════════════════════════════════"
    echo "  SEDE 2"
    echo "═══════════════════════════════════════════════════════════"
    echo "  Contenedor:  p4-switch-sede2"
    echo "  Gestión:     172.16.0.12"
    echo "  Thrift:      9092"
    echo ""
    docker exec p4-switch-sede2 ip -br addr 2>/dev/null | grep -v "lo\|eth0" | head -5 || true
    echo ""
    
    echo "═══════════════════════════════════════════════════════════"
    echo "  BRIDGES OVS (Host)"
    echo "═══════════════════════════════════════════════════════════"
    ovs-vsctl show 2>/dev/null | grep -E "Bridge|Port p4s" | head -20 || true
    echo ""
    
    echo "═══════════════════════════════════════════════════════════"
    echo "  COMANDOS ÚTILES"
    echo "═══════════════════════════════════════════════════════════"
    echo "  Shell Sede 1:    docker exec -it p4-switch-sede1 bash"
    echo "  Shell Sede 2:    docker exec -it p4-switch-sede2 bash"
    echo "  OVS Sede 1:      docker exec p4-switch-sede1 ovs-vsctl show"
    echo "  OVS Sede 2:      docker exec p4-switch-sede2 ovs-vsctl show"
    echo "  Destruir todo:   sudo ./destroy_p4_switches.sh"
    echo ""
}

main() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[✗]${NC} Este script debe ejecutarse con sudo"
        echo "Uso: sudo $0"
        exit 1
    fi
    
    print_banner
    check_scripts
    
    echo -e "${YELLOW}¿Desplegar ambas sedes? (s/n):${NC} "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Ss]$ ]]; then
        echo "Operación cancelada"
        exit 0
    fi
    
    deploy_sede1
    echo ""
    sleep 2
    
    deploy_sede2
    echo ""
    sleep 2
    
    test_connectivity
    show_summary
    
    echo -e "${GREEN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║           ✓ DESPLIEGUE COMPLETADO                         ║"
    echo "║           Ambas sedes operativas                          ║"
    echo "║                                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"
}

main "$@"