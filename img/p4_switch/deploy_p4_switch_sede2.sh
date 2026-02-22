#!/usr/bin/env bash
#==============================================================================
# Switch P4 Consolidado - SEDE 2 (CORREGIDO)
#==============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SWITCH_NAME="p4-switch-sede2"
SEDE_ID="2"
MGMT_NETWORK="p4net"
MGMT_IP="172.16.0.12"
P4_IMAGE="p4lang/behavioral-model"
THRIFT_PORT=9092

ACCESSNET_IP="10.255.0.1"
MPLS_IP="10.20.0.12"
INET_PUBLIC_IP="10.100.2.2"
LAN_BRIDGE_IP="192.168.255.254"

BCG_REMOTE_IP="10.255.0.2"
SEDE1_MPLS_IP="10.20.0.11"
SEDE1_INET_IP="10.100.1.2"
ISP_GATEWAY="10.100.2.254"

# Archivo P4 (debe ser definido por el usuario)

print_header() {
    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC} $1"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}\n"
}

print_info() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

check_prerequisites() {
    print_header "Verificando prerequisitos - Sede ${SEDE_ID}"
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker no instalado"
        exit 1
    fi
    print_info "Docker OK"
    
    if ! command -v ovs-vsctl &> /dev/null; then
        print_error "OVS no instalado"
        exit 1
    fi
    print_info "OVS OK"
    
    local required=("AccessNet2" "MplsWan" "ExtNet2")
    for bridge in "${required[@]}"; do
        if ! ovs-vsctl br-exists "$bridge" 2>/dev/null; then
            print_error "Falta bridge: $bridge"
            exit 1
        fi
    done
    print_info "Bridges OVS disponibles"
}

cleanup_previous() {
    print_header "Limpiando despliegue previo"
    
    docker rm -f ${SWITCH_NAME} 2>/dev/null || true
    ovs-vsctl --if-exists del-port AccessNet2 p4s2-accessnet2 2>/dev/null || true
    ovs-vsctl --if-exists del-port MplsWan p4s2-mpls 2>/dev/null || true
    ovs-vsctl --if-exists del-port ExtNet2 p4s2-inet 2>/dev/null || true
    
    if ! docker network ls --format '{{.Name}}' | grep -q "^${MGMT_NETWORK}$"; then
        docker network create --subnet=172.16.0.0/24 ${MGMT_NETWORK}
    fi
    
    print_info "Limpieza completada"
}

create_container() {
    print_header "Creando contenedor - Sede ${SEDE_ID}"
    
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
        apt-get install -y -qq \
            iproute2 net-tools tcpdump iputils-ping \
            bridge-utils iperf3 iptables \
        2>/dev/null
    " &> /dev/null
    
    print_info "Herramientas instaladas"
}

attach_to_ovs_bridge() {
    local port=$1
    local bridge=$2
    local ip=$3
    local mask=${4:-24}
    
    print_info "Conectando ${port} → ${bridge} (${ip}/${mask})"
    
    ovs-vsctl add-port ${bridge} ${port} -- set interface ${port} type=internal
    ip link set ${port} up
    
    local pid=$(docker inspect -f '{{.State.Pid}}' ${SWITCH_NAME})
    ip link set ${port} netns ${pid}
    
    docker exec ${SWITCH_NAME} ip addr add ${ip}/${mask} dev ${port}
    docker exec ${SWITCH_NAME} ip link set ${port} up
}

setup_interfaces() {
    print_header "Configurando interfaces - Sede ${SEDE_ID}"
    
    attach_to_ovs_bridge "p4s2-accessnet2" "AccessNet2" "${ACCESSNET_IP}" "24"
    attach_to_ovs_bridge "p4s2-mpls" "MplsWan" "${MPLS_IP}" "24"
    attach_to_ovs_bridge "p4s2-inet" "ExtNet2" "${INET_PUBLIC_IP}" "24"
    
    print_info "Interfaces físicas configuradas"
}

setup_vxlan_endpoints() {
    print_header "Configurando endpoints VXLAN"
    
    # VXLAN 1: Cliente WAN/MPLS (sin IP, solo túnel L2)
    docker exec ${SWITCH_NAME} bash -c "
        ip link add vxlan1 type vxlan \
            id 1 \
            remote ${BCG_REMOTE_IP} \
            local ${ACCESSNET_IP} \
            dstport 4789 \
            dev p4s2-accessnet2
        ip link set vxlan1 up
    "
    print_info "VXLAN1: VNI 1 → ${BCG_REMOTE_IP}"
    
    # VXLAN 2: Cliente Internet (con IP 192.168.255.254 - actúa como CPE gateway)
    docker exec ${SWITCH_NAME} bash -c "
        ip link add vxlan2 type vxlan \
            id 2 \
            remote ${BCG_REMOTE_IP} \
            local ${ACCESSNET_IP} \
            dstport 8742 \
            dev p4s2-accessnet2
        ip link set vxlan2 up
        ip addr add ${LAN_BRIDGE_IP}/24 dev vxlan2
    "
    print_info "VXLAN2: VNI 2 → ${BCG_REMOTE_IP} (IP: ${LAN_BRIDGE_IP})"
}

setup_routing_and_nat() {
    print_header "Configurando rutas y NAT"
    
    docker exec ${SWITCH_NAME} sysctl -w net.ipv4.ip_forward=1 > /dev/null
    
    # Ruta hacia LAN local (10.20.2.0/24)
    docker exec ${SWITCH_NAME} ip route add 10.20.2.0/24 dev vxlan1 || true
    print_info "Ruta: 10.20.2.0/24 dev vxlan1 (LAN local)"
    
    # Ruta hacia LAN remota (10.20.1.0/24) - SOLO vía MPLS
    docker exec ${SWITCH_NAME} ip route add 10.20.1.0/24 via ${SEDE1_MPLS_IP} dev p4s2-mpls || true
    print_info "Ruta: 10.20.1.0/24 via ${SEDE1_MPLS_IP} (MPLS)"
    
    # Ruta hacia voip-gw
    docker exec ${SWITCH_NAME} ip route add 10.20.0.254/32 dev p4s2-mpls || true
    print_info "Ruta: 10.20.0.254 (voip-gw via MPLS)"
    
    # Eliminar ruta default de Docker
    docker exec ${SWITCH_NAME} ip route del default via 172.16.0.1 2>/dev/null || true
    
    # Ruta default ÚNICA vía Internet
    docker exec ${SWITCH_NAME} ip route add default via ${ISP_GATEWAY} dev p4s2-inet || true
    print_info "Ruta: default via ${ISP_GATEWAY} (Internet)"
    
    docker exec ${SWITCH_NAME} ip link set p4s2-accessnet2 mtu 1450
    docker exec ${SWITCH_NAME} ip link set vxlan1 mtu 1400
    docker exec ${SWITCH_NAME} ip link set vxlan2 mtu 1400
    
    print_info "Configurando NAT"
    docker exec ${SWITCH_NAME} bash -c "
        iptables -t nat -A POSTROUTING -s 192.168.255.0/24 -o p4s2-inet -j SNAT --to-source ${INET_PUBLIC_IP}
        iptables -A FORWARD -i vxlan2 -o p4s2-inet -j ACCEPT
        iptables -A FORWARD -i p4s2-inet -o vxlan2 -m state --state RELATED,ESTABLISHED -j ACCEPT
        iptables -A FORWARD -i vxlan1 -o p4s2-mpls -j ACCEPT
        iptables -A FORWARD -i p4s2-mpls -o vxlan1 -j ACCEPT
    "
    
    print_info "NAT y forwarding configurados"
}

start_p4_switch() {
    print_header "Iniciando simple_switch"
    
    if [ -n "$P4_CONFIG" ] && [ -f "$P4_CONFIG" ]; then
        print_info "Programa P4 encontrado: $P4_CONFIG"
        
        if ! docker exec ${SWITCH_NAME} test -f /tmp/p4config.json 2>/dev/null; then
            docker cp "$P4_CONFIG" ${SWITCH_NAME}:/tmp/p4config.json
        fi
        
        docker exec -d ${SWITCH_NAME} bash -c "
            simple_switch \
                -i 0@vxlan1 \
                -i 1@vxlan2 \
                -i 2@p4s2-mpls \
                -i 3@p4s2-inet \
                -i 4@p4s2-accessnet2 \
                --thrift-port ${THRIFT_PORT} \
                --nanolog ipc:///tmp/bm-log.ipc \
                --log-console \
                /tmp/p4config.json \
                > /var/log/simple_switch.log 2>&1
        "
        
        sleep 3
        
        if docker exec ${SWITCH_NAME} pgrep -x simple_switch > /dev/null; then
            print_info "✓ simple_switch iniciado correctamente"
        else
            print_error "simple_switch no se inició"
            return 1
        fi
        
    elif [ -n "$P4_CONFIG" ] && [ ! -f "$P4_CONFIG" ]; then
        print_error "P4_CONFIG definido pero archivo no existe: $P4_CONFIG"
        
    else
        print_warning "No hay programa P4 definido"
        print_info "Para usar P4: export P4_CONFIG=\$PWD/sdwan_switch.json"
    fi
}

print_summary() {
    print_header "SWITCH P4 SEDE ${SEDE_ID} DESPLEGADO"
    
    echo -e "${GREEN}✓ Switch P4 operativo${NC}\n"
    
    echo "Contenedor: ${SWITCH_NAME}"
    echo "Gestión:    ${MGMT_IP}"
    echo ""
    docker exec ${SWITCH_NAME} ip -br addr 2>/dev/null | grep -v "lo" || true
    echo ""
}

main() {
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║         SWITCH P4 CONSOLIDADO - SEDE 2                    ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"
    
    check_prerequisites
    cleanup_previous
    create_container
    install_tools
    setup_interfaces
    setup_vxlan_endpoints
    setup_routing_and_nat
    start_p4_switch
    print_summary
    
    echo -e "${GREEN}✓ SEDE 2 LISTA${NC}\n"
}

main "$@"