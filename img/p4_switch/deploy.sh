#!/usr/bin/env bash
#==============================================================================
# deploy_l2.sh - Despliegue SD-WAN P4 en modo BCG L2 transparente
#
# Cambios respecto al diseno con 10.20.0.10:
#   - Los BCG NO tienen IP en 10.20.0.0/24.
#   - r1 usa como gateway remoto a r2: 10.20.0.2.
#   - r2 usa como gateway remoto a r1: 10.20.0.1.
#   - ARP se encapsula en Geneve con TLV 0x00000002.
#   - El BCG preserva la trama Ethernet interna completa.
#   - El decap se hace directamente del puerto access al puerto router.
#   - Se eliminan p4bcgX-out, p4bcgX-tun-in/out y policy routing en BCG.
#
# Puertos BCG:
#   port 0: p4bcgX-router  <-> lan11/lan21
#   port 1: p4bcgX-access  <-> AccessNetX
#
# Puertos Central:
#   port 0: p4cX-access    <-> AccessNetX
#   port 1: p4cX-mpls      <-> MplsWan
#   port 2: p4cX-tun-in    <-> kernel p4cX-tun-out -> wg0
#==============================================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

P4DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P4_BCG_CONFIG="${P4DIR}/bcg_switch.json/bcg_switch.json"
P4_CENTRAL_CONFIG="${P4DIR}/central_switch.json/central_switch.json"
P4_IMAGE="p4lang/behavioral-model"
MGMT_NETWORK="p4net"

BCG1_IP="10.255.0.2"
BCG2_IP="10.255.0.3"
CENTRAL1_IP="10.255.0.1"
CENTRAL2_IP="10.255.0.4"

CENTRAL1_ISP_IP="10.100.1.1"
CENTRAL1_ISP_GW="10.100.1.254"
CENTRAL2_ISP_IP="10.100.2.1"
CENTRAL2_ISP_GW="10.100.2.254"

WG_PORT=51820
WG_C1_IP="192.168.200.1"
WG_C2_IP="192.168.200.2"
WG_SUBNET="192.168.200.0/30"

GENEVE_VNI="100"
TLV_HOSTS="0x00000000"
TLV_PHONES="0x00000001"
TLV_ARP="0x00000002"

WG_DIR="/tmp/sdwan-wg"

print_header() {
    echo -e "\n${CYAN}==========================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}==========================================${NC}\n"
}
print_info()    { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error()   { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

setup_wg_keys() {
    print_header "Gestionando claves WireGuard"
    mkdir -p ${WG_DIR}
    chmod 700 ${WG_DIR}
    [ -f ${WG_DIR}/sede1.priv ] || {
        wg genkey | tee ${WG_DIR}/sede1.priv | wg pubkey > ${WG_DIR}/sede1.pub
        chmod 600 ${WG_DIR}/sede1.priv
        print_info "Claves sede1 generadas"
    }
    [ -f ${WG_DIR}/sede2.priv ] || {
        wg genkey | tee ${WG_DIR}/sede2.priv | wg pubkey > ${WG_DIR}/sede2.pub
        chmod 600 ${WG_DIR}/sede2.priv
        print_info "Claves sede2 generadas"
    }
    WG_PRIV_SEDE1=$(cat ${WG_DIR}/sede1.priv)
    WG_PUB_SEDE1=$(cat ${WG_DIR}/sede1.pub)
    WG_PRIV_SEDE2=$(cat ${WG_DIR}/sede2.priv)
    WG_PUB_SEDE2=$(cat ${WG_DIR}/sede2.pub)
    print_info "Claves WireGuard listas"
}

check_prerequisites() {
    print_header "Verificando prerequisitos"
    [ -f "$P4_BCG_CONFIG" ]     || print_error "bcg_switch.json no existe. Ejecuta compile.sh primero"
    [ -f "$P4_CENTRAL_CONFIG" ] || print_error "central_switch.json no existe. Ejecuta compile.sh primero"
    ovs-vsctl br-exists AccessNet1 2>/dev/null || print_error "Falta bridge OVS AccessNet1"
    ovs-vsctl br-exists AccessNet2 2>/dev/null || print_error "Falta bridge OVS AccessNet2"
    ovs-vsctl br-exists MplsWan    2>/dev/null || print_error "Falta bridge OVS MplsWan"
    ovs-vsctl br-exists ExtNet1    2>/dev/null || print_error "Falta bridge OVS ExtNet1"
    ovs-vsctl br-exists ExtNet2    2>/dev/null || print_error "Falta bridge OVS ExtNet2"
    ip link show lan11 &>/dev/null || print_error "Falta lan11"
    ip link show lan21 &>/dev/null || print_error "Falta lan21"
    command -v wg &>/dev/null || print_error "wireguard-tools no instalado en host"
    if ! docker network ls --format '{{.Name}}' | grep -q "^${MGMT_NETWORK}$"; then
        docker network create --subnet=172.16.0.0/24 ${MGMT_NETWORK}
        print_info "Red Docker ${MGMT_NETWORK} creada"
    fi
    print_info "Prerequisitos OK"
}

create_container() {
    local name=$1 ip=$2
    docker rm -f ${name} 2>/dev/null || true
    docker run -d --rm --name ${name} --network ${MGMT_NETWORK} --ip ${ip} \
        --privileged --cap-add=NET_ADMIN --cap-add=SYS_ADMIN --cap-add=NET_RAW \
        ${P4_IMAGE} bash -c 'tail -f /dev/null'
    sleep 2
    print_info "Contenedor: ${name} (${ip})"
}

install_tools() {
    local name=$1 extra=$2
    docker exec ${name} bash -c "
        apt-get update -qq && \
        apt-get install -y -qq iproute2 tcpdump iputils-ping iptables ${extra} 2>/dev/null
    " &>/dev/null
    print_info "Herramientas instaladas en ${name}"
}

attach_ovs() {
    local name=$1 port=$2 bridge=$3 ip=$4
    ovs-vsctl --if-exists del-port ${port} 2>/dev/null || true
    ovs-vsctl add-port ${bridge} ${port} -- set interface ${port} type=internal
    ip link set ${port} up
    local pid; pid=$(docker inspect -f '{{.State.Pid}}' ${name})
    ip link set ${port} netns ${pid}
    [ -n "$ip" ] && docker exec ${name} ip addr add ${ip}/24 dev ${port}
    docker exec ${name} ip link set ${port} up
    print_info "${port} -> ${bridge}$([ -n "$ip" ] && echo " (${ip}/24)" || echo " (L2)")"
}

attach_linux() {
    local name=$1 port=$2 bridge=$3 host_end=$4
    ip link del ${host_end} 2>/dev/null || true
    ip link del ${port} 2>/dev/null || true
    ip link add ${host_end} type veth peer name ${port}
    ip link set ${host_end} up
    ip link set ${host_end} master ${bridge}
    local pid; pid=$(docker inspect -f '{{.State.Pid}}' ${name})
    ip link set ${port} netns ${pid}
    docker exec ${name} ip link set ${port} up
    print_info "${port} -> ${bridge} (host: ${host_end})"
}

create_internal_veth() {
    local name=$1 inner=$2 outer=$3
    docker exec ${name} bash -c "
        ip link add ${inner} type veth peer name ${outer}
        ip link set ${inner} up
        ip link set ${outer} up
    "
    print_info "Veth interno: ${inner} <-> ${outer}"
}

get_mac() { docker exec $1 cat /sys/class/net/$2/address; }

ip2hex() {
    local IFS=.
    local a b c d
    read -r a b c d <<< "$1"
    printf '0x%02X%02X%02X%02X' "$a" "$b" "$c" "$d"
}

run_p4_cli() {
    local name=$1 thrift=$2 commands=$3
    docker exec ${name} bash -c "
        simple_switch_CLI --thrift-port ${thrift} <<'CLITABLES'
${commands}
CLITABLES
    "
}

deploy_central1() {
    print_header "Desplegando Central P4 - SEDE 1"
    ovs-vsctl --if-exists del-port p4c1-access 2>/dev/null || true
    ovs-vsctl --if-exists del-port p4c1-mpls 2>/dev/null || true
    ovs-vsctl --if-exists del-port p4c1-isp 2>/dev/null || true
    create_container "p4-central-sede1" "172.16.0.11"
    install_tools "p4-central-sede1" "wireguard-tools"
    attach_ovs "p4-central-sede1" "p4c1-access" "AccessNet1" "${CENTRAL1_IP}"
    attach_ovs "p4-central-sede1" "p4c1-mpls"   "MplsWan"    ""
    attach_ovs "p4-central-sede1" "p4c1-isp"    "ExtNet1"    "${CENTRAL1_ISP_IP}"
    create_internal_veth "p4-central-sede1" "p4c1-tun-in" "p4c1-tun-out"

    docker exec p4-central-sede1 bash -c "
        ip link add wg0 type wireguard
        echo '${WG_PRIV_SEDE1}' | wg set wg0 listen-port ${WG_PORT} private-key /dev/stdin
        wg set wg0 peer ${WG_PUB_SEDE2} endpoint ${CENTRAL2_ISP_IP}:${WG_PORT} \
            allowed-ips ${WG_SUBNET},${BCG2_IP}/32,${BCG1_IP}/32 persistent-keepalive 25
        ip addr add ${WG_C1_IP}/30 dev wg0
        ip link set wg0 up
        ip link set wg0 mtu 1380
        echo 1 > /proc/sys/net/ipv4/ip_forward
        echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
        echo 0 > /proc/sys/net/ipv4/conf/p4c1-tun-out/rp_filter
        iptables -I FORWARD 1 -i p4c1-mpls -p udp --dport 6081 -j DROP
        iptables -I FORWARD 1 -i p4c1-access -p udp --dport 6081 -j DROP
        ip route replace default via ${CENTRAL1_ISP_GW} dev p4c1-isp
        echo '201 p4fwd' >> /etc/iproute2/rt_tables 2>/dev/null || true
        ip rule add iif p4c1-tun-out table 201 priority 100 2>/dev/null || true
        ip route replace default dev wg0 table 201
        ip route replace ${BCG2_IP}/32 dev wg0 table 201
        ip route replace ${BCG1_IP}/32 dev p4c1-tun-out
        ip neigh replace ${BCG1_IP} lladdr 02:00:00:00:01:02 dev p4c1-tun-out nud permanent
        iptables -I INPUT -i p4c1-tun-out -p udp --dport 6081 -j DROP
    "

    docker cp "$P4_CENTRAL_CONFIG" p4-central-sede1:/tmp/p4config.json
    docker exec -d p4-central-sede1 bash -c "simple_switch -i 0@p4c1-access -i 1@p4c1-mpls -i 2@p4c1-tun-in --thrift-port 9091 --log-console /tmp/p4config.json > /var/log/simple_switch.log 2>&1"
    sleep 3
    docker exec p4-central-sede1 pgrep -x simple_switch >/dev/null || print_error "simple_switch central1 no arranco"

    local tun_in_mac tun_out_mac mpls_mac
    tun_in_mac=$(get_mac p4-central-sede1 p4c1-tun-in)
    tun_out_mac=$(get_mac p4-central-sede1 p4c1-tun-out)
    mpls_mac=$(get_mac p4-central-sede1 p4c1-mpls)

    run_p4_cli "p4-central-sede1" "9091" "
table_add forward_geneve_from_access rewrite_and_forward ${TLV_HOSTS}&&&0xFFFFFFFF 0 => 2 ${tun_in_mac} ${tun_out_mac} $(ip2hex ${BCG1_IP}) $(ip2hex ${BCG2_IP}) 100
table_add forward_geneve_from_access rewrite_and_forward ${TLV_ARP}&&&0xFFFFFFFF 0 => 2 ${tun_in_mac} ${tun_out_mac} $(ip2hex ${BCG1_IP}) $(ip2hex ${BCG2_IP}) 100
"
    print_info "Central1 desplegada"
}

deploy_central2() {
    print_header "Desplegando Central P4 - SEDE 2"
    ovs-vsctl --if-exists del-port p4c2-access 2>/dev/null || true
    ovs-vsctl --if-exists del-port p4c2-mpls 2>/dev/null || true
    ovs-vsctl --if-exists del-port p4c2-isp 2>/dev/null || true
    create_container "p4-central-sede2" "172.16.0.12"
    install_tools "p4-central-sede2" "wireguard-tools"
    attach_ovs "p4-central-sede2" "p4c2-access" "AccessNet2" "${CENTRAL2_IP}"
    attach_ovs "p4-central-sede2" "p4c2-mpls"   "MplsWan"    ""
    attach_ovs "p4-central-sede2" "p4c2-isp"    "ExtNet2"    "${CENTRAL2_ISP_IP}"
    create_internal_veth "p4-central-sede2" "p4c2-tun-in" "p4c2-tun-out"

    docker exec p4-central-sede2 bash -c "
        ip link add wg0 type wireguard
        echo '${WG_PRIV_SEDE2}' | wg set wg0 listen-port ${WG_PORT} private-key /dev/stdin
        wg set wg0 peer ${WG_PUB_SEDE1} endpoint ${CENTRAL1_ISP_IP}:${WG_PORT} \
            allowed-ips ${WG_SUBNET},${BCG1_IP}/32,${BCG2_IP}/32 persistent-keepalive 25
        ip addr add ${WG_C2_IP}/30 dev wg0
        ip link set wg0 up
        ip link set wg0 mtu 1380
        echo 1 > /proc/sys/net/ipv4/ip_forward
        echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
        echo 0 > /proc/sys/net/ipv4/conf/p4c2-tun-out/rp_filter
        iptables -I FORWARD 1 -i p4c2-mpls -p udp --dport 6081 -j DROP
        iptables -I FORWARD 1 -i p4c2-access -p udp --dport 6081 -j DROP
        ip route replace default via ${CENTRAL2_ISP_GW} dev p4c2-isp
        echo '201 p4fwd' >> /etc/iproute2/rt_tables 2>/dev/null || true
        ip rule add iif p4c2-tun-out table 201 priority 100 2>/dev/null || true
        ip route replace default dev wg0 table 201
        ip route replace ${BCG1_IP}/32 dev wg0 table 201
        ip route replace ${BCG2_IP}/32 dev p4c2-tun-out
        ip neigh replace ${BCG2_IP} lladdr 02:00:00:00:02:03 dev p4c2-tun-out nud permanent
        iptables -I INPUT -i p4c2-tun-out -p udp --dport 6081 -j DROP
    "

    docker cp "$P4_CENTRAL_CONFIG" p4-central-sede2:/tmp/p4config.json
    docker exec -d p4-central-sede2 bash -c "simple_switch -i 0@p4c2-access -i 1@p4c2-mpls -i 2@p4c2-tun-in --thrift-port 9092 --log-console /tmp/p4config.json > /var/log/simple_switch.log 2>&1"
    sleep 3
    docker exec p4-central-sede2 pgrep -x simple_switch >/dev/null || print_error "simple_switch central2 no arranco"

    local tun_in_mac tun_out_mac mpls_mac
    tun_in_mac=$(get_mac p4-central-sede2 p4c2-tun-in)
    tun_out_mac=$(get_mac p4-central-sede2 p4c2-tun-out)
    mpls_mac=$(get_mac p4-central-sede2 p4c2-mpls)

    run_p4_cli "p4-central-sede2" "9092" "
table_add forward_geneve_from_access rewrite_and_forward ${TLV_HOSTS}&&&0xFFFFFFFF 0 => 2 ${tun_in_mac} ${tun_out_mac} $(ip2hex ${BCG2_IP}) $(ip2hex ${BCG1_IP}) 100
table_add forward_geneve_from_access rewrite_and_forward ${TLV_ARP}&&&0xFFFFFFFF 0 => 2 ${tun_in_mac} ${tun_out_mac} $(ip2hex ${BCG2_IP}) $(ip2hex ${BCG1_IP}) 100
"
    print_info "Central2 desplegada"
}

deploy_bcg() {
    local sede=$1 num=$2 lan=$3 bcg_ip=$4 central_name=$5 central_access=$6 thrift=$7 mgmt_ip=$8
    local name="p4-bcg-${sede}"
    local rport="p4bcg${num}-router"
    local aport="p4bcg${num}-access"
    local veth_rou="veth-p4bcg${num}-rou"
    print_header "Desplegando BCG L2 P4 - ${sede}"

    docker rm -f ${name} 2>/dev/null || true
    ovs-vsctl --if-exists del-port ${aport} 2>/dev/null || true
    ip link del ${veth_rou} 2>/dev/null || true
    ip link del ${rport} 2>/dev/null || true

    create_container "${name}" "${mgmt_ip}"
    install_tools "${name}" ""
    attach_linux "${name}" "${rport}" "${lan}" "${veth_rou}"
    attach_ovs "${name}" "${aport}" "AccessNet${num}" "${bcg_ip}"

    docker cp "$P4_BCG_CONFIG" ${name}:/tmp/p4config.json
    docker exec -d ${name} bash -c "simple_switch -i 0@${rport} -i 1@${aport} --thrift-port ${thrift} --log-console /tmp/p4config.json > /var/log/simple_switch.log 2>&1"
    sleep 3
    docker exec ${name} pgrep -x simple_switch >/dev/null || print_error "simple_switch ${name} no arranco"

    local bcg_mac cen_mac bcg_hex cen_hex
    bcg_mac=$(get_mac ${name} ${aport})
    cen_mac=$(get_mac ${central_name} ${central_access})
    if [ "${num}" = "1" ]; then
        bcg_hex=$(ip2hex ${BCG1_IP})
        cen_hex=$(ip2hex ${CENTRAL1_IP})
    else
        bcg_hex=$(ip2hex ${BCG2_IP})
        cen_hex=$(ip2hex ${CENTRAL2_IP})
    fi

    run_p4_cli "${name}" "${thrift}" "
table_add from_router_ipv4 encap_geneve_ipv4 10.20.1.0/25 0 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} ${TLV_HOSTS}
table_add from_router_ipv4 encap_geneve_ipv4 10.20.1.128/25 0 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} ${TLV_PHONES}
table_add from_router_ipv4 encap_geneve_ipv4 10.20.2.0/25 0 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} ${TLV_HOSTS}
table_add from_router_ipv4 encap_geneve_ipv4 10.20.2.128/25 0 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} ${TLV_PHONES}
table_add from_router_arp encap_geneve_arp 0 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} ${TLV_ARP}
table_add from_access_ipv4 decap_geneve_ipv4 1 => 0
table_add from_access_arp decap_geneve_arp 1 => 0
"
    print_info "BCG${num} desplegado como L2 transparente"
}

populate_mpls_and_return_tables() {
    print_header "Poblando tablas MPLS y retorno"
    local c1_access c2_access b1_access b2_access c1_mpls c2_mpls
    c1_access=$(get_mac p4-central-sede1 p4c1-access)
    c2_access=$(get_mac p4-central-sede2 p4c2-access)
    b1_access=$(get_mac p4-bcg-sede1 p4bcg1-access)
    b2_access=$(get_mac p4-bcg-sede2 p4bcg2-access)
    c1_mpls=$(get_mac p4-central-sede1 p4c1-mpls)
    c2_mpls=$(get_mac p4-central-sede2 p4c2-mpls)

    run_p4_cli "p4-central-sede1" "9091" "
table_add forward_geneve_from_access rewrite_and_forward ${TLV_PHONES}&&&0xFFFFFFFF 0 => 1 ${c1_mpls} ${c2_mpls} $(ip2hex ${CENTRAL1_IP}) $(ip2hex ${BCG2_IP}) 100
table_add forward_geneve_to_access rewrite_and_forward 1 => 0 ${c1_access} ${b1_access} $(ip2hex ${CENTRAL1_IP}) $(ip2hex ${BCG1_IP})
table_add forward_geneve_to_access rewrite_and_forward 2 => 0 ${c1_access} ${b1_access} $(ip2hex ${CENTRAL1_IP}) $(ip2hex ${BCG1_IP})
"
    run_p4_cli "p4-central-sede2" "9092" "
table_add forward_geneve_from_access rewrite_and_forward ${TLV_PHONES}&&&0xFFFFFFFF 0 => 1 ${c2_mpls} ${c1_mpls} $(ip2hex ${CENTRAL2_IP}) $(ip2hex ${BCG1_IP}) 100
table_add forward_geneve_to_access rewrite_and_forward 1 => 0 ${c2_access} ${b2_access} $(ip2hex ${CENTRAL2_IP}) $(ip2hex ${BCG2_IP})
table_add forward_geneve_to_access rewrite_and_forward 2 => 0 ${c2_access} ${b2_access} $(ip2hex ${CENTRAL2_IP}) $(ip2hex ${BCG2_IP})
"
    print_info "Tablas de centrales completas"
}

verify() {
    print_header "Verificacion"
    echo "WireGuard central1:"
    docker exec p4-central-sede1 wg show 2>/dev/null | grep -E "peer|handshake|transfer" || true
    echo ""
    docker exec p4-central-sede1 ping -c2 -W2 ${WG_C2_IP} >/dev/null 2>&1 \
        && print_info "Tunel WireGuard operativo" \
        || print_warning "WireGuard sin respuesta aun"
    echo ""
    echo "Pruebas sugeridas:"
    echo "  vnx_console h1 -> ping 10.20.2.2"
    echo "  vnx_console t1 -> ping 10.20.2.200"
    echo "  Captura ARP: docker exec -it p4-bcg-sede1 tcpdump -nni p4bcg1-access udp port 6081"
}

main() {
    echo -e "${CYAN}"
    echo "=========================================="
    echo "  SD-WAN P4 - despliegue L2 transparente"
    echo "=========================================="
    echo -e "${NC}"
    setup_wg_keys
    check_prerequisites
    deploy_central1
    deploy_central2
    deploy_bcg "sede1" "1" "lan11" "${BCG1_IP}" "p4-central-sede1" "p4c1-access" "9093" "172.16.0.21"
    deploy_bcg "sede2" "2" "lan21" "${BCG2_IP}" "p4-central-sede2" "p4c2-access" "9094" "172.16.0.22"
    populate_mpls_and_return_tables
    verify
    print_info "Despliegue L2 completado"
}

main
