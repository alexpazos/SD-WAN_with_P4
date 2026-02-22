#!/usr/bin/env bash
#==============================================================================
# Switch P4 Simple - SEDE 2
# 2 interfaces: vxlan1 + p4s2-mpls
# Bridging L2 simple entre ambas
#==============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SWITCH_NAME="p4-switch-sede2"
MGMT_NETWORK="p4net"
MGMT_IP="172.16.0.12"
P4_IMAGE="p4lang/behavioral-model"
THRIFT_PORT=9092

ACCESSNET_IP="10.255.0.1"
MPLS_IP="10.20.0.12"
BCG_REMOTE_IP="10.255.0.2"

print_header() {
    echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}\n"
}

print_info() { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

check_prerequisites() {
    print_header "Verificando prerequisitos"
    command -v docker &> /dev/null || print_error "Docker no instalado"
    command -v ovs-vsctl &> /dev/null || print_error "OVS no instalado"
    ovs-vsctl br-exists AccessNet2 2>/dev/null || print_error "Falta: AccessNet2"
    ovs-vsctl br-exists MplsWan 2>/dev/null || print_error "Falta: MplsWan"
    print_info "Prerequisitos OK"
}

cleanup_previous() {
    print_header "Limpiando"
    docker rm -f ${SWITCH_NAME} 2>/dev/null || true
    ovs-vsctl --if-exists del-port AccessNet2 p4s2-accessnet2 2>/dev/null || true
    ovs-vsctl --if-exists del-port MplsWan p4s2-mpls 2>/dev/null || true
    if ! docker network ls --format '{{.Name}}' | grep -q "^${MGMT_NETWORK}$"; then
        docker network create --subnet=172.16.0.0/24 ${MGMT_NETWORK}
    fi
    print_info "Limpieza OK"
}

create_container() {
    print_header "Creando contenedor"
    docker run -d --rm \
        --name ${SWITCH_NAME} \
        --network ${MGMT_NETWORK} \
        --ip ${MGMT_IP} \
        --privileged \
        --cap-add=NET_ADMIN \
        --cap-add=SYS_ADMIN \
        --cap-add=NET_RAW \
        ${P4_IMAGE} \
        bash -c 'tail -f /dev/null'
    sleep 2
    print_info "Contenedor: ${SWITCH_NAME}"
}

install_tools() {
    print_header "Instalando herramientas"
    docker exec ${SWITCH_NAME} bash -c "
        apt-get update -qq && \
        apt-get install -y -qq iproute2 tcpdump iputils-ping 2>/dev/null
    " &> /dev/null
    print_info "Herramientas OK"
}

attach_to_ovs_bridge() {
    local port=$1
    local bridge=$2
    local ip=$3
    
    print_info "Conectando ${port} → ${bridge}"
    ovs-vsctl add-port ${bridge} ${port} -- set interface ${port} type=internal
    ip link set ${port} up
    local pid=$(docker inspect -f '{{.State.Pid}}' ${SWITCH_NAME})
    ip link set ${port} netns ${pid}
    docker exec ${SWITCH_NAME} ip addr add ${ip}/24 dev ${port}
    docker exec ${SWITCH_NAME} ip link set ${port} up
}

setup_interfaces() {
    print_header "Configurando interfaces"
    echo -e "${BLUE}Switch P4 Sede 2 - 2 INTERFACES${NC}"
    echo "  Port 0: vxlan1    → AccessNet2"
    echo "  Port 1: p4s2-mpls → MplsWan"
    echo ""
    attach_to_ovs_bridge "p4s2-accessnet2" "AccessNet2" "${ACCESSNET_IP}"
    attach_to_ovs_bridge "p4s2-mpls" "MplsWan" "${MPLS_IP}"
}

setup_vxlan() {
    print_header "Configurando VXLAN1"
    docker exec ${SWITCH_NAME} bash -c "
        ip link add vxlan1 type vxlan \
            id 1 \
            remote ${BCG_REMOTE_IP} \
            local ${ACCESSNET_IP} \
            dstport 4789 \
            dev p4s2-accessnet2
        ip link set vxlan1 up
        ip link set vxlan1 mtu 1400
    "
    print_info "VXLAN1: VNI 1 → ${BCG_REMOTE_IP}"
}

start_p4_switch() {
    print_header "Iniciando simple_switch"
    
    if [ -z "$P4_CONFIG" ] || [ ! -f "$P4_CONFIG" ]; then
        print_error "P4_CONFIG no definido: $P4_CONFIG"
    fi
    
    docker cp "$P4_CONFIG" ${SWITCH_NAME}:/tmp/p4config.json
    
    docker exec -d ${SWITCH_NAME} bash -c "
        simple_switch \
            -i 0@vxlan1 \
            -i 1@p4s2-mpls \
            --thrift-port ${THRIFT_PORT} \
            --log-console \
            /tmp/p4config.json \
            > /var/log/simple_switch.log 2>&1
    "
    
    sleep 3
    
    if docker exec ${SWITCH_NAME} pgrep -x simple_switch > /dev/null; then
        print_info "✓ simple_switch corriendo"
    else
        print_error "simple_switch falló"
    fi
}

print_summary() {
    print_header "RESUMEN - Sede 2"
    echo "Contenedor: ${SWITCH_NAME}"
    echo "Test desde r2: ping 10.20.0.12"
    echo ""
}

main() {
    echo -e "${CYAN}╔════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  SWITCH P4 SIMPLE - SEDE 2    ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════╝${NC}\n"
    
    check_prerequisites
    cleanup_previous
    create_container
    install_tools
    setup_interfaces
    setup_vxlan
    start_p4_switch
    print_summary
    
    echo -e "${GREEN}✓ SEDE 2 LISTA${NC}\n"
}

main
