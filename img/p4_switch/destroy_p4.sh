#!/usr/bin/env bash
#==============================================================================
# Destrucción completa de ambos switches P4
#==============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

confirm_destruction() {
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║         DESTRUCCIÓN DE SWITCHES P4 SD-WAN                 ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"
    
    echo -e "${RED}¡ADVERTENCIA!${NC}"
    echo ""
    echo "Esta acción eliminará:"
    echo "  • Contenedor: p4-switch-sede1"
    echo "  • Contenedor: p4-switch-sede2"
    echo "  • Red Docker: p4net"
    echo "  • Puertos OVS: p4s1-*, p4s2-*"
    echo "  • Bridges OVS internos (brwan, brint)"
    echo ""
    echo -e "${YELLOW}Esta acción NO se puede deshacer.${NC}"
    echo ""
    
    read -p "¿Continuar? (escribe 'SI' para confirmar): " confirm
    
    if [ "$confirm" != "SI" ]; then
        echo "Operación cancelada"
        exit 0
    fi
}

stop_containers() {
    echo -e "\n${CYAN}Deteniendo contenedores...${NC}\n"
    
    for container in "p4-switch-sede1" "p4-switch-sede2"; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            echo -e "${GREEN}[✓]${NC} Deteniendo: $container"
            docker stop $container 2>/dev/null || true
            docker rm $container 2>/dev/null || true
        else
            echo -e "${YELLOW}[!]${NC} $container no existe"
        fi
    done
}

cleanup_ovs_ports() {
    echo -e "\n${CYAN}Limpiando puertos OVS...${NC}\n"
    
    local ports_s1=("p4s1-accessnet1" "p4s1-mpls" "p4s1-inet")
    local ports_s2=("p4s2-accessnet2" "p4s2-mpls" "p4s2-inet")
    local bridges=("AccessNet1" "AccessNet2" "MplsWan" "ExtNet1" "ExtNet2")
    
    local removed=0
    
    for port in "${ports_s1[@]}"; do
        for bridge in "${bridges[@]}"; do
            if ovs-vsctl --if-exists del-port $bridge $port 2>/dev/null; then
                echo -e "${GREEN}[✓]${NC} $port eliminado de $bridge"
                removed=$((removed + 1))
            fi
        done
    done
    
    for port in "${ports_s2[@]}"; do
        for bridge in "${bridges[@]}"; do
            if ovs-vsctl --if-exists del-port $bridge $port 2>/dev/null; then
                echo -e "${GREEN}[✓]${NC} $port eliminado de $bridge"
                removed=$((removed + 1))
            fi
        done
    done
    
    echo ""
    echo -e "${GREEN}[✓]${NC} $removed puertos OVS eliminados"
}

cleanup_docker_network() {
    echo -e "\n${CYAN}Limpiando red Docker...${NC}\n"
    
    if docker network ls --format '{{.Name}}' | grep -q "^p4net$"; then
        docker network rm p4net 2>/dev/null || true
        echo -e "${GREEN}[✓]${NC} Red p4net eliminada"
    else
        echo -e "${YELLOW}[!]${NC} Red p4net no existe"
    fi
}

verify_cleanup() {
    echo -e "\n${CYAN}Verificando limpieza...${NC}\n"
    
    local errors=0
    
    # Contenedores
    for container in "p4-switch-sede1" "p4-switch-sede2"; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            echo -e "${RED}[✗]${NC} $container todavía existe"
            errors=$((errors + 1))
        else
            echo -e "${GREEN}[✓]${NC} $container eliminado"
        fi
    done
    
    # Red
    if docker network ls --format '{{.Name}}' | grep -q "^p4net$"; then
        echo -e "${RED}[✗]${NC} Red p4net todavía existe"
        errors=$((errors + 1))
    else
        echo -e "${GREEN}[✓]${NC} Red p4net eliminada"
    fi
    
    # Puertos OVS
    local remaining=0
    for bridge in AccessNet1 AccessNet2 MplsWan ExtNet1 ExtNet2; do
        if ovs-vsctl br-exists $bridge 2>/dev/null; then
            local ports=$(ovs-vsctl list-ports $bridge 2>/dev/null | grep -c "^p4s" || true)
            remaining=$((remaining + ports))
        fi
    done
    
    if [ $remaining -gt 0 ]; then
        echo -e "${YELLOW}[!]${NC} $remaining puertos OVS aún existen"
    else
        echo -e "${GREEN}[✓]${NC} Todos los puertos OVS eliminados"
    fi
    
    echo ""
    
    if [ $errors -eq 0 ]; then
        echo -e "${GREEN}✓ Limpieza completada exitosamente${NC}"
    else
        echo -e "${YELLOW}⚠ Limpieza completada con $errors errores${NC}"
    fi
}

show_summary() {
    echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  RESUMEN"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}\n"
    
    echo "Recursos eliminados:"
    echo "  ✓ Contenedores: p4-switch-sede1, p4-switch-sede2"
    echo "  ✓ Red Docker: p4net"
    echo "  ✓ Puertos OVS: p4s1-*, p4s2-*"
    echo "  ✓ Bridges internos: brwan, brint (dentro de contenedores)"
    echo ""
    echo "Bridges OVS NO eliminados (usados por VNX/Containerlab):"
    echo "  • AccessNet1, AccessNet2, MplsWan, ExtNet1, ExtNet2"
    echo ""
    echo "Para volver a desplegar:"
    echo "  $ sudo ./deploy_p4_switches.sh"
    echo ""
}

main() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[✗]${NC} Este script debe ejecutarse con sudo"
        exit 1
    fi
    
    # Modo forzado
    if [ "$1" != "-f" ] && [ "$1" != "--force" ]; then
        confirm_destruction
    else
        echo -e "${YELLOW}[!]${NC} Modo forzado activado"
    fi
    
    stop_containers
    cleanup_ovs_ports
    cleanup_docker_network
    verify_cleanup
    show_summary
    
    echo -e "${GREEN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║           ✓ DESTRUCCIÓN COMPLETADA                        ║"
    echo "║                                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"
}

main "$@"