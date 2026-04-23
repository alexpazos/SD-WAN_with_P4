#!/usr/bin/env bash
#==============================================================================
# Switch P4 SD-WAN - SEDE 2
# Port 0: vxlan1         → BCG (AccessNet2, VNI 1, puerto 4789)
# Port 1: p4s2-mpls      → MplsWan (teléfonos L2)
# Port 2: vxlan2         → túnel inter-sede (VNI 2, puerto 4790) → p4s2-isp
# Port 3: p4s2-nat-inner → kernel NAT (MASQUERADE) → p4s2-isp → ISP/internet
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
BCG_REMOTE_IP="10.255.0.2"
ISP_IP="10.100.2.1"
ISP_GW="10.100.2.254"
REMOTE_ISP_IP="10.100.1.1"

# Subredes de clientes: el retorno NAT las necesita para volver a P4
CLIENT_SUBNET_SEDE1="10.20.1.0/24"
CLIENT_SUBNET_SEDE2="10.20.2.0/24"

print_header() {
    echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}\n"
}

print_info()    { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }

check_prerequisites() {
    print_header "Verificando prerequisitos"
    command -v docker    &>/dev/null || print_error "Docker no instalado"
    command -v ovs-vsctl &>/dev/null || print_error "OVS no instalado"
    ovs-vsctl br-exists AccessNet2 2>/dev/null || print_error "Falta bridge: AccessNet2"
    ovs-vsctl br-exists MplsWan   2>/dev/null || print_error "Falta bridge: MplsWan"
    ovs-vsctl br-exists ExtNet2   2>/dev/null || print_error "Falta bridge: ExtNet2"
    print_info "Docker y OVS disponibles"
    print_info "Bridges OVS: AccessNet2, MplsWan, ExtNet2"
}

cleanup_previous() {
    print_header "Limpiando despliegue previo"
    docker rm -f ${SWITCH_NAME} 2>/dev/null || true
    ovs-vsctl --if-exists del-port AccessNet2 p4s2-accessnet2 2>/dev/null || true
    ovs-vsctl --if-exists del-port MplsWan    p4s2-mpls       2>/dev/null || true
    ovs-vsctl --if-exists del-port ExtNet2    p4s2-isp        2>/dev/null || true
    if ! docker network ls --format '{{.Name}}' | grep -q "^${MGMT_NETWORK}$"; then
        docker network create --subnet=172.16.0.0/24 ${MGMT_NETWORK}
    fi
    print_info "Limpieza completada"
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
    print_info "Contenedor creado: ${SWITCH_NAME} (${MGMT_IP})"
}

install_tools() {
    print_header "Instalando herramientas"
    docker exec ${SWITCH_NAME} bash -c "
        apt-get update -qq && \
        apt-get install -y -qq iproute2 tcpdump iputils-ping iptables arping 2>/dev/null
    " &>/dev/null
    print_info "Herramientas instaladas"
}

attach_to_ovs_bridge() {
    local port=$1
    local bridge=$2
    local ip=$3

    ovs-vsctl add-port ${bridge} ${port} -- set interface ${port} type=internal
    ip link set ${port} up
    local pid
    pid=$(docker inspect -f '{{.State.Pid}}' ${SWITCH_NAME})
    ip link set ${port} netns ${pid}

    if [ -n "$ip" ]; then
        docker exec ${SWITCH_NAME} ip addr add ${ip}/24 dev ${port}
        print_info "${port} → ${bridge} (${ip}/24)"
    else
        print_info "${port} → ${bridge} (L2, sin IP)"
    fi
    docker exec ${SWITCH_NAME} ip link set ${port} up
}

setup_interfaces() {
    print_header "Configurando interfaces OVS"

    echo -e "${BLUE}"
    echo "┌────────────────────────────────────────────────────────────┐"
    echo "│  Switch P4 SD-WAN Sede 2                                  │"
    echo "├────────────────────────────────────────────────────────────┤"
    echo "│  Port 0 (P4): vxlan1        → AccessNet2 (BCG)            │"
    echo "│  Port 1 (P4): p4s2-mpls     → MplsWan (teléfonos)         │"
    echo "│  Port 2 (P4): vxlan2        → túnel inter-sede            │"
    echo "│  Port 3 (P4): p4s2-nat-inner→ kernel NAT → internet       │"
    echo "│  Kernel:      p4s2-isp      → ExtNet2 (vxlan2 + NAT)      │"
    echo "└────────────────────────────────────────────────────────────┘"
    echo -e "${NC}\n"

    # AccessNet2: CON IP (endpoint VXLAN hacia BCG)
    attach_to_ovs_bridge "p4s2-accessnet2" "AccessNet2" "${ACCESSNET_IP}"

    # MplsWan: SIN IP (L2 puro para teléfonos)
    attach_to_ovs_bridge "p4s2-mpls" "MplsWan" ""

    # ExtNet2: CON IP (interfaz subyacente de vxlan2 Y salida NAT internet)
    attach_to_ovs_bridge "p4s2-isp" "ExtNet2" "${ISP_IP}"
}

setup_vxlan_bcg() {
    print_header "Configurando túnel VXLAN → BCG"

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
    print_info "vxlan1: VNI 1, puerto 4789, ${ACCESSNET_IP} → ${BCG_REMOTE_IP}"
}

setup_vxlan_intersede() {
    print_header "Configurando túnel VXLAN inter-sede"

    docker exec ${SWITCH_NAME} bash -c "
        ip link add vxlan2 type vxlan \
            id 2 \
            remote ${REMOTE_ISP_IP} \
            local ${ISP_IP} \
            dstport 4790 \
            dev p4s2-isp
        ip link set vxlan2 up
        ip link set vxlan2 mtu 1400
    "
    print_info "vxlan2: VNI 2, puerto 4790, ${ISP_IP} → ${REMOTE_ISP_IP}"
}

setup_nat_iface() {
    print_header "Configurando interfaz virtual NAT (port 3)"

    docker exec ${SWITCH_NAME} bash -c "
        ip link add p4s2-nat-inner type veth peer name p4s2-nat-outer
        ip link set p4s2-nat-inner up
        ip link set p4s2-nat-outer up
    "
    print_info "Par veth NAT creado:"
    print_info "  p4s2-nat-inner → P4 port 3"
    print_info "  p4s2-nat-outer → kernel (MASQUERADE → p4s2-isp)"
}

setup_routing() {
    print_header "Configurando routing kernel"

    docker exec ${SWITCH_NAME} bash -c "
        echo 1 > /proc/sys/net/ipv4/ip_forward

        # Ruta por defecto: tráfico NATado sale por p4s2-isp hacia ISP
        ip route replace default via ${ISP_GW} dev p4s2-isp

        # Rutas de retorno NAT:
        # Cuando internet responde, conntrack deshace el NAT (dst→10.20.x.x)
        # y el kernel necesita saber cómo llegar a esas IPs: por p4s2-nat-outer → P4
        ip route add ${CLIENT_SUBNET_SEDE1} dev p4s2-nat-outer
        ip route add ${CLIENT_SUBNET_SEDE2} dev p4s2-nat-outer
    "
    print_info "ip_forward activado"
    print_info "Ruta por defecto → ${ISP_GW} (p4s2-isp)"
    print_info "Retorno NAT ${CLIENT_SUBNET_SEDE1} → p4s2-nat-outer → P4 port3"
    print_info "Retorno NAT ${CLIENT_SUBNET_SEDE2} → p4s2-nat-outer → P4 port3"
}

setup_nat_rules() {
    print_header "Configurando NAT (iptables MASQUERADE)"

    docker exec ${SWITCH_NAME} bash -c "
        # MASQUERADE: cuando un paquete sale por p4s2-isp,
        # sustituye la IP origen (10.20.x.x) por ${ISP_IP}
        # conntrack guarda el mapeo para el retorno
        iptables -t nat -A POSTROUTING -o p4s2-isp -j MASQUERADE

        # Permitir reenvío entre el par veth NAT y p4s2-isp
        iptables -A FORWARD -i p4s2-nat-outer -o p4s2-isp      -j ACCEPT
        iptables -A FORWARD -i p4s2-isp       -o p4s2-nat-outer -j ACCEPT
    "
    print_info "MASQUERADE activo: salida por p4s2-isp → src sustituida por ${ISP_IP}"
    print_info "FORWARD habilitado: p4s2-nat-outer ↔ p4s2-isp"
}

start_p4_switch() {
    print_header "Iniciando simple_switch"

    if [ -z "$P4_CONFIG" ] || [ ! -f "$P4_CONFIG" ]; then
        print_error "P4_CONFIG no definido o archivo no existe: $P4_CONFIG"
    fi

    print_info "Programa P4: $P4_CONFIG"
    docker cp "$P4_CONFIG" ${SWITCH_NAME}:/tmp/p4config.json

    docker exec -d ${SWITCH_NAME} bash -c "
        simple_switch \
            -i 0@vxlan1 \
            -i 1@p4s2-mpls \
            -i 2@vxlan2 \
            -i 3@p4s2-nat-inner \
            --thrift-port ${THRIFT_PORT} \
            --log-console \
            /tmp/p4config.json \
            > /var/log/simple_switch.log 2>&1
    "

    sleep 3

    if docker exec ${SWITCH_NAME} pgrep -x simple_switch >/dev/null; then
        print_info "simple_switch corriendo (thrift: ${THRIFT_PORT})"
        echo ""
        echo -e "${CYAN}  CLI: docker exec -it ${SWITCH_NAME} simple_switch_CLI --thrift-port ${THRIFT_PORT}${NC}"
    else
        print_error "simple_switch no arrancó. Ver: docker exec ${SWITCH_NAME} cat /var/log/simple_switch.log"
    fi
}

setup_p4_tables() {
    print_header "Poblando tablas P4"

    # Solo rutas hacia redes REMOTAS (sede1)
    # Tráfico local sede2 llega por port 0 → to_bcg (port 0 no pasa por routing)
    # Tráfico internet no tiene match → default_action to_nat → port 3
    docker exec ${SWITCH_NAME} bash -c "
        simple_switch_CLI --thrift-port ${THRIFT_PORT} << 'EOF'
table_add routing to_mpls 10.20.1.128/25 =>
table_add routing to_isp  10.20.1.0/25   =>
EOF
    "

    print_info "Tabla routing poblada (sede2 → solo redes remotas):"
    print_info "  10.20.1.128/25 → Port 1 (p4s2-mpls, teléfonos sede1 vía MPLS)"
    print_info "  10.20.1.0/25   → Port 2 (vxlan2, hosts sede1 vía ISP)"
    print_info "  default        → Port 3 (p4s2-nat-inner, internet vía NAT)"
}

print_summary() {
    print_header "RESUMEN SEDE 2"

    echo "Contenedor : ${SWITCH_NAME}"
    echo "Gestión    : ${MGMT_IP}"
    echo ""
    echo "Interfaces:"
    docker exec ${SWITCH_NAME} ip -br addr 2>/dev/null | grep -v "^lo\|^eth0" || true
    echo ""
    echo "Rutas kernel:"
    docker exec ${SWITCH_NAME} ip route 2>/dev/null || true
    echo ""
    echo "NAT (iptables):"
    docker exec ${SWITCH_NAME} iptables -t nat -L POSTROUTING -n -v 2>/dev/null || true
    echo ""
    echo "Flujos de tráfico:"
    echo ""
    echo "  [INTER-SEDE h2→h1]"
    echo "  BCG→vxlan1→P4(port0) dst∈10.20.1.0/25 → to_isp → port2(vxlan2)"
    echo "  kernel encapsula VNI2:4790 src=${ISP_IP} dst=${REMOTE_ISP_IP}"
    echo "  p4s2-isp → ExtNet2 → ISP → sede1"
    echo ""
    echo "  [INTERNET h2→8.8.8.8]"
    echo "  BCG→vxlan1→P4(port0) dst=8.8.8.8 → default to_nat → port3"
    echo "  p4s2-nat-inner → p4s2-nat-outer → MASQUERADE src→${ISP_IP}"
    echo "  p4s2-isp → ExtNet2 → ISP → internet"
    echo ""
    echo "  [RETORNO INTERNET 8.8.8.8→h2]"
    echo "  ISP→p4s2-isp → conntrack deshace NAT dst→10.20.2.2"
    echo "  ruta 10.20.2.0/24 dev p4s2-nat-outer → P4(port3) → to_bcg → port0"
    echo "  vxlan1 → BCG → h2"
    echo ""
    echo "  [TELEFONOS t2→t1]"
    echo "  BCG→vxlan1→P4(port0) dst∈10.20.1.128/25 → to_mpls → port1"
    echo "  p4s2-mpls → MplsWan → R1/R2 → sede1"
}

main() {
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════╗"
    echo "║   SWITCH P4 SD-WAN - SEDE 2               ║"
    echo "║   MPLS + VXLAN inter-sede + NAT internet   ║"
    echo "╚════════════════════════════════════════════╝"
    echo -e "${NC}\n"

    check_prerequisites
    cleanup_previous
    create_container
    install_tools
    setup_interfaces
    setup_vxlan_bcg
    setup_vxlan_intersede
    setup_nat_iface
    setup_routing
    setup_nat_rules
    start_p4_switch
    setup_p4_tables
    print_summary

    echo -e "\n${GREEN}✓ SEDE 2 DESPLEGADA Y OPERATIVA${NC}\n"
}

main