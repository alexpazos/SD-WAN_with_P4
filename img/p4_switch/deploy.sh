#!/usr/bin/env bash
#==============================================================================
# deploy.sh — Desplegar BCGs y Centrales SD-WAN P4
#
# Arquitectura BCG (Opción A — sin bucles):
#   Encap (router→access):
#     r1/r2 → veth-p4bcgX-rou → p4bcgX-router (P4 port 0) → encap →
#             p4bcgX-access (P4 port 1) → AccessNet → central
#
#   Decap (access→router):
#     central → AccessNet → p4bcgX-access (port 1) → decap →
#               p4bcgX-tun-in (port 2) → [veth interno] →
#               p4bcgX-tun-out (kernel) → policy routing →
#               p4bcgX-out → veth-p4bcgX-out → lan11/lan21 → r1/r2
#
#   Esta vía de retorno NO pasa por P4 port 0, evitando bucles.
#
# Arquitectura Central:
#   BCG → p4cX-access (port 0) → P4 inspecciona TLV
#     hosts:  reescribe outer IP → port 2 (veth → kernel → wg0 cifrado → ISP)
#     phones: reescribe outer IP → port 1 (MplsWan)
#   Retorno: port 1 o 2 → forward_geneve_to_access → port 0 → BCG local
#
# Prerequisitos:
#   - Escenario VNX arrancado (hosts, routers, bridges Linux lan11 y lan21)
#   - Bridges OVS creados (AccessNet1/2, MplsWan, ExtNet1/2)
#   - Programas P4 compilados (compile.sh)
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

# IPs en AccessNet (10.255.0.0/24)
BCG1_IP="10.255.0.2"
BCG2_IP="10.255.0.3"
CENTRAL1_IP="10.255.0.1"
CENTRAL2_IP="10.255.0.4"

# IPs en ExtNet
CENTRAL1_ISP_IP="10.100.1.1"
CENTRAL1_ISP_GW="10.100.1.254"
CENTRAL2_ISP_IP="10.100.2.1"
CENTRAL2_ISP_GW="10.100.2.254"

# WireGuard
WG_PORT=51820
WG_C1_IP="192.168.200.1"
WG_C2_IP="192.168.200.2"
WG_SUBNET="192.168.200.0/30"

# IPs router-side BCG (cada bridge L2 aislado, misma IP en ambos)
BCG_ROUTER_IP="10.20.0.10"
R1_IP="10.20.0.1"
R2_IP="10.20.0.2"

GENEVE_VNI="100"

WG_DIR="/tmp/sdwan-wg"

print_header() {
    echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}\n"
}
print_info()    { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }

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
    [ -f "$P4_BCG_CONFIG" ]     || print_error "bcg_switch.json no existe (compila primero)"
    [ -f "$P4_CENTRAL_CONFIG" ] || print_error "central_switch.json no existe (compila primero)"
    ovs-vsctl br-exists AccessNet1 2>/dev/null || print_error "Falta bridge OVS AccessNet1"
    ovs-vsctl br-exists AccessNet2 2>/dev/null || print_error "Falta bridge OVS AccessNet2"
    ovs-vsctl br-exists MplsWan    2>/dev/null || print_error "Falta bridge OVS MplsWan"
    ovs-vsctl br-exists ExtNet1    2>/dev/null || print_error "Falta bridge OVS ExtNet1"
    ovs-vsctl br-exists ExtNet2    2>/dev/null || print_error "Falta bridge OVS ExtNet2"
    ip link show lan11 &>/dev/null || print_error "Falta bridge Linux lan11 (¿VNX arrancado?)"
    ip link show lan21 &>/dev/null || print_error "Falta bridge Linux lan21 (¿VNX arrancado?)"
    command -v wg &>/dev/null || print_error "wireguard-tools (wg) no instalado en host"
    if ! docker network ls --format '{{.Name}}' | grep -q "^${MGMT_NETWORK}$"; then
        docker network create --subnet=172.16.0.0/24 ${MGMT_NETWORK}
        print_info "Red Docker ${MGMT_NETWORK} creada"
    fi
    print_info "Prerequisitos OK"
}

create_container() {
    local name=$1 ip=$2
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
    ovs-vsctl add-port ${bridge} ${port} -- set interface ${port} type=internal
    ip link set ${port} up
    local pid; pid=$(docker inspect -f '{{.State.Pid}}' ${name})
    ip link set ${port} netns ${pid}
    [ -n "$ip" ] && docker exec ${name} ip addr add ${ip}/24 dev ${port}
    docker exec ${name} ip link set ${port} up
    print_info "${port} → ${bridge}$([ -n "$ip" ] && echo " (${ip}/24)" || echo " (L2)")"
}

attach_linux() {
    local name=$1 port=$2 bridge=$3 host_end=$4
    [ -z "$host_end" ] && host_end="veth-${port:0:10}"
    ip link add ${host_end} type veth peer name ${port}
    ip link set ${host_end} up
    ip link set ${host_end} master ${bridge}
    local pid; pid=$(docker inspect -f '{{.State.Pid}}' ${name})
    ip link set ${port} netns ${pid}
    docker exec ${name} ip link set ${port} up
    print_info "${port} → ${bridge} (Linux bridge, host: ${host_end})"
}

create_internal_veth() {
    local name=$1 inner=$2 outer=$3
    docker exec ${name} bash -c "
        ip link add ${inner} type veth peer name ${outer}
        ip link set ${inner} up
        ip link set ${outer} up
    "
    print_info "Veth interno: ${inner} ↔ ${outer}"
}

get_mac() {
    docker exec $1 cat /sys/class/net/$2/address
}

run_p4_cli() {
    local name=$1 thrift=$2 commands=$3
    docker exec ${name} bash -c "
        simple_switch_CLI --thrift-port ${thrift} <<'CLITABLES'
${commands}
CLITABLES
    "
}

#==============================================================================
deploy_central1() {
    print_header "Desplegando Switch P4 Central - SEDE 1"

    docker rm -f p4-central-sede1 2>/dev/null || true
    ovs-vsctl --if-exists del-port AccessNet1 p4c1-access 2>/dev/null || true
    ovs-vsctl --if-exists del-port MplsWan    p4c1-mpls   2>/dev/null || true
    ovs-vsctl --if-exists del-port ExtNet1    p4c1-isp    2>/dev/null || true

    create_container "p4-central-sede1" "172.16.0.11"
    install_tools "p4-central-sede1" "wireguard-tools"

    attach_ovs "p4-central-sede1" "p4c1-access" "AccessNet1" "${CENTRAL1_IP}"
    attach_ovs "p4-central-sede1" "p4c1-mpls"   "MplsWan"    ""
    attach_ovs "p4-central-sede1" "p4c1-isp"    "ExtNet1"    "${CENTRAL1_ISP_IP}"

    create_internal_veth "p4-central-sede1" "p4c1-tun-in" "p4c1-tun-out"

    docker exec p4-central-sede1 bash -c "
        ip link add wg0 type wireguard
        echo '${WG_PRIV_SEDE1}' | wg set wg0 listen-port ${WG_PORT} private-key /dev/stdin
        wg set wg0 peer ${WG_PUB_SEDE2} \
            endpoint ${CENTRAL2_ISP_IP}:${WG_PORT} \
            allowed-ips ${WG_SUBNET},${BCG2_IP}/32 \
            persistent-keepalive 25
        ip addr add ${WG_C1_IP}/30 dev wg0
        ip link set wg0 up
        ip link set wg0 mtu 1380

        echo 1 > /proc/sys/net/ipv4/ip_forward
        echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
        echo 0 > /proc/sys/net/ipv4/conf/p4c1-tun-out/rp_filter

        ip route replace default via ${CENTRAL1_ISP_GW} dev p4c1-isp

        echo '201 p4fwd' >> /etc/iproute2/rt_tables 2>/dev/null || true
        ip rule add iif p4c1-tun-out table 201 priority 100
        ip route add default dev wg0 table 201
        ip route add ${BCG2_IP}/32 dev wg0 table 201

        # Tráfico Geneve que vuelve desde WireGuard hacia el BCG local:
        # forzarlo a entrar al P4 por el veth interno, no sacarlo directo por AccessNet.
        # La MAC falsa evita que el kernel consuma/reinyecte el frame en el peer del veth.
        ip route replace ${BCG1_IP}/32 dev p4c1-tun-out
        ip neigh replace ${BCG1_IP} lladdr 02:00:00:00:01:02 dev p4c1-tun-out nud permanent

        iptables -I INPUT -i p4c1-tun-out -p udp --dport 6081 -j DROP
    "
    print_info "WireGuard wg0: ${WG_C1_IP} → ${CENTRAL2_ISP_IP}:${WG_PORT}"

    docker cp "$P4_CENTRAL_CONFIG" p4-central-sede1:/tmp/p4config.json
    docker exec -d p4-central-sede1 bash -c "
        simple_switch -i 0@p4c1-access -i 1@p4c1-mpls -i 2@p4c1-tun-in \
            --thrift-port 9091 --log-console /tmp/p4config.json \
            > /var/log/simple_switch.log 2>&1
    "
    sleep 3
    docker exec p4-central-sede1 pgrep -x simple_switch >/dev/null \
        || print_error "simple_switch no arrancó"
    print_info "simple_switch corriendo (thrift: 9091)"

    local tun_in_mac;  tun_in_mac=$(get_mac p4-central-sede1 p4c1-tun-in)
    local tun_out_mac; tun_out_mac=$(get_mac p4-central-sede1 p4c1-tun-out)

    # central1 reescribe: src=BCG1(0x0AFF0002) externo (no central local)
    #                     dst=BCG2(0x0AFF0003) remoto
    run_p4_cli "p4-central-sede1" "9091" "
table_add forward_geneve_from_access rewrite_and_forward 0x00000000&&&0x00000001 => 2 ${tun_in_mac} ${tun_out_mac} 0x0AFF0002 0x0AFF0003 1
table_add forward_geneve_from_access rewrite_and_forward 0x00000001&&&0x00000001 => 1 00:00:00:00:00:00 00:00:00:00:00:00 0x0AFF0001 0x0AFF0003 2
"
    print_info "Tabla forward_geneve_from_access poblada (central1)"
}

#==============================================================================
deploy_central2() {
    print_header "Desplegando Switch P4 Central - SEDE 2"

    docker rm -f p4-central-sede2 2>/dev/null || true
    ovs-vsctl --if-exists del-port AccessNet2 p4c2-access 2>/dev/null || true
    ovs-vsctl --if-exists del-port MplsWan    p4c2-mpls   2>/dev/null || true
    ovs-vsctl --if-exists del-port ExtNet2    p4c2-isp    2>/dev/null || true

    create_container "p4-central-sede2" "172.16.0.12"
    install_tools "p4-central-sede2" "wireguard-tools"

    attach_ovs "p4-central-sede2" "p4c2-access" "AccessNet2" "${CENTRAL2_IP}"
    attach_ovs "p4-central-sede2" "p4c2-mpls"   "MplsWan"    ""
    attach_ovs "p4-central-sede2" "p4c2-isp"    "ExtNet2"    "${CENTRAL2_ISP_IP}"

    create_internal_veth "p4-central-sede2" "p4c2-tun-in" "p4c2-tun-out"

    docker exec p4-central-sede2 bash -c "
        ip link add wg0 type wireguard
        echo '${WG_PRIV_SEDE2}' | wg set wg0 listen-port ${WG_PORT} private-key /dev/stdin
        wg set wg0 peer ${WG_PUB_SEDE1} \
            endpoint ${CENTRAL1_ISP_IP}:${WG_PORT} \
            allowed-ips ${WG_SUBNET},${BCG1_IP}/32 \
            persistent-keepalive 25
        ip addr add ${WG_C2_IP}/30 dev wg0
        ip link set wg0 up
        ip link set wg0 mtu 1380

        echo 1 > /proc/sys/net/ipv4/ip_forward
        echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
        echo 0 > /proc/sys/net/ipv4/conf/p4c2-tun-out/rp_filter

        ip route replace default via ${CENTRAL2_ISP_GW} dev p4c2-isp

        echo '201 p4fwd' >> /etc/iproute2/rt_tables 2>/dev/null || true
        ip rule add iif p4c2-tun-out table 201 priority 100
        ip route add default dev wg0 table 201
        ip route add ${BCG1_IP}/32 dev wg0 table 201

        # Tráfico Geneve que vuelve desde WireGuard hacia el BCG local:
        # forzarlo a entrar al P4 por el veth interno, no sacarlo directo por AccessNet.
        # La MAC falsa evita que el kernel consuma/reinyecte el frame en el peer del veth.
        ip route replace ${BCG2_IP}/32 dev p4c2-tun-out
        ip neigh replace ${BCG2_IP} lladdr 02:00:00:00:02:03 dev p4c2-tun-out nud permanent

        iptables -I INPUT -i p4c2-tun-out -p udp --dport 6081 -j DROP
    "
    print_info "WireGuard wg0: ${WG_C2_IP} → ${CENTRAL1_ISP_IP}:${WG_PORT}"

    docker cp "$P4_CENTRAL_CONFIG" p4-central-sede2:/tmp/p4config.json
    docker exec -d p4-central-sede2 bash -c "
        simple_switch -i 0@p4c2-access -i 1@p4c2-mpls -i 2@p4c2-tun-in \
            --thrift-port 9092 --log-console /tmp/p4config.json \
            > /var/log/simple_switch.log 2>&1
    "
    sleep 3
    docker exec p4-central-sede2 pgrep -x simple_switch >/dev/null \
        || print_error "simple_switch no arrancó"
    print_info "simple_switch corriendo (thrift: 9092)"

    local tun_in_mac;  tun_in_mac=$(get_mac p4-central-sede2 p4c2-tun-in)
    local tun_out_mac; tun_out_mac=$(get_mac p4-central-sede2 p4c2-tun-out)

    # central2 reescribe: src=BCG2(0x0AFF0003) externo, dst=BCG1(0x0AFF0002)
    run_p4_cli "p4-central-sede2" "9092" "
table_add forward_geneve_from_access rewrite_and_forward 0x00000000&&&0x00000001 => 2 ${tun_in_mac} ${tun_out_mac} 0x0AFF0003 0x0AFF0002 1
table_add forward_geneve_from_access rewrite_and_forward 0x00000001&&&0x00000001 => 1 00:00:00:00:00:00 00:00:00:00:00:00 0x0AFF0004 0x0AFF0002 2
"
    print_info "Tabla forward_geneve_from_access poblada (central2)"
}

#==============================================================================
deploy_bcg() {
    local sede=$1 num=$2 lan=$3 router_ip=$4 bcg_ip=$5 central_name=$6 \
          central_access=$7 thrift=$8 mgmt_ip=$9

    local name="p4-bcg-${sede}"
    local rport="p4bcg${num}-router"
    local aport="p4bcg${num}-access"
    local tin="p4bcg${num}-tun-in"
    local tout="p4bcg${num}-tun-out"
    local outp="p4bcg${num}-out"
    local veth_rou="veth-p4bcg${num}-rou"
    local veth_out="veth-p4bcg${num}-out"

    print_header "Desplegando BCG P4 - ${sede^^}"

    docker rm -f ${name} 2>/dev/null || true
    ovs-vsctl --if-exists del-port "AccessNet${num}" ${aport} 2>/dev/null || true
    ip link del ${veth_rou} 2>/dev/null || true
    ip link del ${veth_out} 2>/dev/null || true
    ip link del ${rport}    2>/dev/null || true
    ip link del ${outp}     2>/dev/null || true

    create_container "${name}" "${mgmt_ip}"
    install_tools "${name}" ""

    # Port 0: router
    attach_linux "${name}" "${rport}" "${lan}" "${veth_rou}"
    docker exec ${name} ip addr add ${BCG_ROUTER_IP}/24 dev ${rport}

    # Port 1: access
    attach_ovs "${name}" "${aport}" "AccessNet${num}" "${bcg_ip}"

    # Port 2: veth interno
    create_internal_veth "${name}" "${tin}" "${tout}"

    # Veth externo: kernel → lan (NO pasa por P4)
    ip link add ${veth_out} type veth peer name ${outp}
    ip link set ${veth_out} up
    ip link set ${veth_out} master ${lan}
    local pid; pid=$(docker inspect -f '{{.State.Pid}}' ${name})
    ip link set ${outp} netns ${pid}
    docker exec ${name} ip link set ${outp} up
    print_info "Veth externo: ${outp} ↔ ${veth_out} (${lan})"

    # Configurar kernel para reenviar inner IP por p4bcgX-out hacia router
    docker exec ${name} bash -c "
        echo 1 > /proc/sys/net/ipv4/ip_forward
        echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
        echo 0 > /proc/sys/net/ipv4/conf/${tout}/rp_filter
        echo 0 > /proc/sys/net/ipv4/conf/${outp}/rp_filter

        # NO asignar ${BCG_ROUTER_IP} a ${outp}: esa IP debe vivir solo en ${rport}.
        # Si también estuviera en ${outp}, el router podría aprender el gateway por la
        # interfaz equivocada y el tráfico saltaría el P4 o crearía bucles L2.

        # Evitar ARP débil de Linux entre las dos interfaces del BCG en la misma LAN.
        for i in all default ${rport} ${outp}; do
            sysctl -w net.ipv4.conf.\${i}.arp_ignore=1
            sysctl -w net.ipv4.conf.\${i}.arp_announce=2
            sysctl -w net.ipv4.conf.\${i}.arp_filter=1
        done

        # Policy routing: paquetes que entran por tun-out → tabla 200 → router.
        # onlink es necesario porque ${outp} no tiene IPv4 propia en 10.20.0.0/24.
        echo '200 p4decap' >> /etc/iproute2/rt_tables 2>/dev/null || true
        ip rule add iif ${tout} table 200 priority 100 2>/dev/null || true
        ip route replace default via ${router_ip} dev ${outp} onlink table 200
    "
    print_info "Kernel: policy routing tabla 200 → ${router_ip} via ${outp}"

    # Lanzar simple_switch
    docker cp "$P4_BCG_CONFIG" ${name}:/tmp/p4config.json
    docker exec -d ${name} bash -c "
        simple_switch -i 0@${rport} -i 1@${aport} -i 2@${tin} \
            --thrift-port ${thrift} --log-console /tmp/p4config.json \
            > /var/log/simple_switch.log 2>&1
    "
    sleep 3
    docker exec ${name} pgrep -x simple_switch >/dev/null \
        || print_error "simple_switch no arrancó"
    print_info "simple_switch corriendo (thrift: ${thrift})"

    local bcg_mac;     bcg_mac=$(get_mac ${name} ${aport})
    local cen_mac;     cen_mac=$(get_mac ${central_name} ${central_access})
    local tin_mac;     tin_mac=$(get_mac ${name} ${tin})
    local tout_mac;    tout_mac=$(get_mac ${name} ${tout})

    # Hex IP del BCG local y central local
    local bcg_hex cen_hex
    bcg_hex=$(printf "0x0AFF000%X" "${num}")
    if [ "$num" = "1" ]; then
        bcg_hex="0x0AFF0002"
        cen_hex="0x0AFF0001"
    else
        bcg_hex="0x0AFF0003"
        cen_hex="0x0AFF0004"
    fi

    run_p4_cli "${name}" "${thrift}" "
table_add from_router encap_geneve_tlv 10.20.1.0/25 0 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} 0x00000000
table_add from_router encap_geneve_tlv 10.20.1.128/25 0 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} 0x00000001
table_add from_router encap_geneve_tlv 10.20.2.0/25 0 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} 0x00000000
table_add from_router encap_geneve_tlv 10.20.2.128/25 0 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} 0x00000001
table_add from_access decap_geneve 10.20.1.0/24 1 => 2 ${tin_mac} ${tout_mac}
table_add from_access decap_geneve 10.20.2.0/24 1 => 2 ${tin_mac} ${tout_mac}
"
    print_info "Tablas BCG${num} pobladas"
}

#==============================================================================
populate_central_return_tables() {
    print_header "Poblando tablas de retorno en centrales"

    local c1_mac; c1_mac=$(get_mac p4-central-sede1 p4c1-access)
    local c2_mac; c2_mac=$(get_mac p4-central-sede2 p4c2-access)
    local b1_mac; b1_mac=$(get_mac p4-bcg-sede1 p4bcg1-access)
    local b2_mac; b2_mac=$(get_mac p4-bcg-sede2 p4bcg2-access)

    run_p4_cli "p4-central-sede1" "9091" "
table_add forward_geneve_to_access rewrite_and_forward 1 => 0 ${c1_mac} ${b1_mac} 0x0AFF0001 0x0AFF0002
table_add forward_geneve_to_access rewrite_and_forward 2 => 0 ${c1_mac} ${b1_mac} 0x0AFF0001 0x0AFF0002
"
    print_info "Central1 retorno → BCG1 (${b1_mac})"

    run_p4_cli "p4-central-sede2" "9092" "
table_add forward_geneve_to_access rewrite_and_forward 1 => 0 ${c2_mac} ${b2_mac} 0x0AFF0004 0x0AFF0003
table_add forward_geneve_to_access rewrite_and_forward 2 => 0 ${c2_mac} ${b2_mac} 0x0AFF0004 0x0AFF0003
"
    print_info "Central2 retorno → BCG2 (${b2_mac})"
}

#==============================================================================
verify() {
    print_header "Verificación"
    echo "WireGuard handshake central1:"
    docker exec p4-central-sede1 wg show 2>/dev/null | grep -E "peer|handshake|transfer" || true
    echo ""
    echo "Ping WireGuard ${WG_C1_IP} → ${WG_C2_IP}:"
    docker exec p4-central-sede1 ping -c2 -W2 ${WG_C2_IP} >/dev/null 2>&1 \
        && print_info "Túnel WireGuard operativo" \
        || print_warning "WireGuard sin respuesta aún (puede tardar)"
}

#==============================================================================
main() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════╗"
    echo "║   SD-WAN P4 — Despliegue                ║"
    echo "║   Geneve + WireGuard (Opción A)          ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"

    setup_wg_keys
    check_prerequisites
    deploy_central1
    deploy_central2
    deploy_bcg "sede1" "1" "lan11" "${R1_IP}" "${BCG1_IP}" "p4-central-sede1" "p4c1-access" "9093" "172.16.0.21"
    deploy_bcg "sede2" "2" "lan21" "${R2_IP}" "${BCG2_IP}" "p4-central-sede2" "p4c2-access" "9094" "172.16.0.22"
    populate_central_return_tables
    verify

    echo -e "\n${GREEN}✓ DESPLIEGUE COMPLETADO${NC}"
    echo ""
    echo "Pruebas:"
    echo "  vnx_console h1 → ping 10.20.2.2     (hosts cifrado por WireGuard)"
    echo "  vnx_console t1 → ping 10.20.2.200   (teléfonos por MplsWan)"
    echo ""
    echo "Claves WireGuard guardadas en: ${WG_DIR}/"
}

main
