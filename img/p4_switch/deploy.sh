#!/usr/bin/env bash
#==============================================================================
# deploy.sh - SD-WAN P4 L2 transparente + MPLS raw + CPE/NAT Internet
#
# Puertos BCG:
#   port 0: p4bcgX-router <-> lan11/lan21        (10.20.0.0/24 intersede/MPLS)
#   port 1: p4bcgX-access <-> AccessNetX         (Geneve hacia central)
#   port 2: p4bcgX-cpe    <-> lan12/lan22        (192.168.255.0/24 Internet/CPE)
#
# Puertos Central:
#   port 0: p4cX-access <-> AccessNetX
#   port 1: p4cX-mpls   <-> MplsWan              (raw L2 para telefonos/ARP/voip)
#   port 2: p4cX-tun-in <-> p4cX-tun-out kernel  (WireGuard + CPE/NAT)
#==============================================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
P4DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P4_BCG_CONFIG="${P4DIR}/bcg_switch.json/bcg_switch.json"
P4_CENTRAL_CONFIG="${P4DIR}/central_switch.json/central_switch.json"
P4_IMAGE="p4lang/behavioral-model"
MGMT_NETWORK="p4net"

BCG1_IP="10.255.0.2"; BCG2_IP="10.255.0.3"
CENTRAL1_IP="10.255.0.1"; CENTRAL2_IP="10.255.0.4"
CENTRAL1_ISP_IP="10.100.1.1"; CENTRAL1_ISP_GW="10.100.1.254"
CENTRAL2_ISP_IP="10.100.2.1"; CENTRAL2_ISP_GW="10.100.2.254"
WG_PORT=51820; WG_C1_IP="192.168.200.1"; WG_C2_IP="192.168.200.2"; WG_SUBNET="192.168.200.0/30"
GENEVE_VNI="100"
TLV_HOSTS="0x00000000"; TLV_PHONES="0x00000001"; TLV_ARP="0x00000002"; TLV_INTERNET="0x00000003"
CPE_IP="192.168.255.254"; R_CPE_IP="192.168.255.253"
WG_DIR="/tmp/sdwan-wg"

print_header(){ echo -e "\n${CYAN}==========================================${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}==========================================${NC}\n"; }
print_info(){ echo -e "${GREEN}[OK]${NC} $1"; }
print_warning(){ echo -e "${YELLOW}[!]${NC} $1"; }
print_error(){ echo -e "${RED}[ERR]${NC} $1"; exit 1; }

setup_wg_keys(){
  print_header "Gestionando claves WireGuard"
  mkdir -p ${WG_DIR}; chmod 700 ${WG_DIR}
  [ -f ${WG_DIR}/sede1.priv ] || { wg genkey | tee ${WG_DIR}/sede1.priv | wg pubkey > ${WG_DIR}/sede1.pub; chmod 600 ${WG_DIR}/sede1.priv; }
  [ -f ${WG_DIR}/sede2.priv ] || { wg genkey | tee ${WG_DIR}/sede2.priv | wg pubkey > ${WG_DIR}/sede2.pub; chmod 600 ${WG_DIR}/sede2.priv; }
  WG_PRIV_SEDE1=$(cat ${WG_DIR}/sede1.priv); WG_PUB_SEDE1=$(cat ${WG_DIR}/sede1.pub)
  WG_PRIV_SEDE2=$(cat ${WG_DIR}/sede2.priv); WG_PUB_SEDE2=$(cat ${WG_DIR}/sede2.pub)
  print_info "Claves WireGuard listas"
}

check_prerequisites(){
  print_header "Verificando prerequisitos"
  [ -f "$P4_BCG_CONFIG" ] || print_error "bcg_switch.json no existe. Ejecuta compile.sh primero"
  [ -f "$P4_CENTRAL_CONFIG" ] || print_error "central_switch.json no existe. Ejecuta compile.sh primero"
  for br in AccessNet1 AccessNet2 MplsWan ExtNet1 ExtNet2; do ovs-vsctl br-exists $br 2>/dev/null || print_error "Falta bridge OVS $br"; done
  for l in lan11 lan21 lan12 lan22; do ip link show $l &>/dev/null || print_error "Falta $l"; done
  command -v wg &>/dev/null || print_error "wireguard-tools no instalado en host"
  if ! docker network ls --format '{{.Name}}' | grep -q "^${MGMT_NETWORK}$"; then docker network create --subnet=172.16.0.0/24 ${MGMT_NETWORK}; fi
  print_info "Prerequisitos OK"
}

create_container(){
  local name=$1 ip=$2
  docker rm -f ${name} 2>/dev/null || true
  docker run -d --rm --name ${name} --network ${MGMT_NETWORK} --ip ${ip} --privileged --cap-add=NET_ADMIN --cap-add=SYS_ADMIN --cap-add=NET_RAW ${P4_IMAGE} bash -c 'tail -f /dev/null'
  sleep 2; print_info "Contenedor: ${name} (${ip})"
}
install_tools(){ local name=$1 extra=$2; docker exec ${name} bash -c "apt-get update -qq && apt-get install -y -qq iproute2 tcpdump iputils-ping iptables ${extra} 2>/dev/null" &>/dev/null; print_info "Herramientas instaladas en ${name}"; }
attach_ovs(){
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
attach_linux(){
  local name=$1 port=$2 bridge=$3 host_end=$4
  ip link del ${host_end} 2>/dev/null || true; ip link del ${port} 2>/dev/null || true
  ip link add ${host_end} type veth peer name ${port}
  ip link set ${host_end} up; ip link set ${host_end} master ${bridge}
  local pid; pid=$(docker inspect -f '{{.State.Pid}}' ${name})
  ip link set ${port} netns ${pid}; docker exec ${name} ip link set ${port} up
  print_info "${port} -> ${bridge} (host: ${host_end})"
}
create_internal_veth(){ local name=$1 inner=$2 outer=$3; docker exec ${name} bash -c "ip link add ${inner} type veth peer name ${outer}; ip link set ${inner} up; ip link set ${outer} up"; print_info "Veth interno: ${inner} <-> ${outer}"; }
get_mac(){ docker exec $1 cat /sys/class/net/$2/address; }
ip2hex(){ local IFS=.; local a b c d; read -r a b c d <<< "$1"; printf '0x%02X%02X%02X%02X' "$a" "$b" "$c" "$d"; }
run_p4_cli(){ local name=$1 thrift=$2 commands=$3; docker exec ${name} bash -c "simple_switch_CLI --thrift-port ${thrift} <<'CLITABLES'
${commands}
CLITABLES"; }

common_central_kernel_config(){
  local name=$1 tun_out=$2 isp=$3 isp_ip=$4 isp_gw=$5 local_lan=$6 fake_bcg_ip=$7 fake_mac=$8 remote_bcg_ip=$9 wg_peer_pub=${10} wg_endpoint=${11} wg_ip=${12} wg_priv=${13}
  local access_if="${isp/isp/access}"
  local mpls_if="${isp/isp/mpls}"
  docker exec ${name} bash -c "
    ip link add wg0 type wireguard
    echo '${wg_priv}' | wg set wg0 listen-port ${WG_PORT} private-key /dev/stdin
    wg set wg0 peer ${wg_peer_pub} endpoint ${wg_endpoint}:${WG_PORT} allowed-ips ${WG_SUBNET},${remote_bcg_ip}/32 persistent-keepalive 25
    ip addr add ${wg_ip}/30 dev wg0
    ip link set wg0 up
    ip link set wg0 mtu 1380
    ip addr add ${CPE_IP}/24 dev ${tun_out} 2>/dev/null || true
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
    echo 0 > /proc/sys/net/ipv4/conf/${tun_out}/rp_filter
    echo 0 > /proc/sys/net/ipv4/conf/${isp}/rp_filter
    iptables -I FORWARD 1 -i ${access_if} -j DROP 2>/dev/null || true
    iptables -I INPUT 1 -i ${access_if} -p udp --dport 6081 -j DROP
    iptables -I FORWARD 1 -i ${mpls_if} -j DROP 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o ${isp} -j SNAT --to-source ${isp_ip}
    iptables -A FORWARD -i ${tun_out} -o ${isp} -j ACCEPT
    iptables -A FORWARD -i ${isp} -o ${tun_out} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip route replace default via ${isp_gw} dev ${isp}
    ip route replace ${local_lan} via ${R_CPE_IP} dev ${tun_out} onlink
    ip route replace ${remote_bcg_ip}/32 dev wg0
    ip route replace ${fake_bcg_ip}/32 dev ${tun_out}
    ip neigh replace ${fake_bcg_ip} lladdr ${fake_mac} dev ${tun_out} nud permanent
    iptables -I INPUT -i ${tun_out} -p udp --dport 6081 -j DROP
  "
}
deploy_central1(){
  print_header "Desplegando Central P4 - SEDE 1"
  for p in p4c1-access p4c1-mpls p4c1-isp; do ovs-vsctl --if-exists del-port $p 2>/dev/null || true; done
  create_container "p4-central-sede1" "172.16.0.11"; install_tools "p4-central-sede1" "wireguard-tools"
  attach_ovs "p4-central-sede1" "p4c1-access" "AccessNet1" "${CENTRAL1_IP}"
  attach_ovs "p4-central-sede1" "p4c1-mpls" "MplsWan" ""
  attach_ovs "p4-central-sede1" "p4c1-isp" "ExtNet1" "${CENTRAL1_ISP_IP}"
  create_internal_veth "p4-central-sede1" "p4c1-tun-in" "p4c1-tun-out"
  common_central_kernel_config "p4-central-sede1" "p4c1-tun-out" "p4c1-isp" "${CENTRAL1_ISP_IP}" "${CENTRAL1_ISP_GW}" "10.20.1.0/24" "${BCG1_IP}" "02:00:00:00:01:02" "${BCG2_IP}" "${WG_PUB_SEDE2}" "${CENTRAL2_ISP_IP}" "${WG_C1_IP}" "${WG_PRIV_SEDE1}"
  docker cp "$P4_CENTRAL_CONFIG" p4-central-sede1:/tmp/p4config.json
  docker exec -d p4-central-sede1 bash -c "simple_switch -i 0@p4c1-access -i 1@p4c1-mpls -i 2@p4c1-tun-in --thrift-port 9091 --log-console /tmp/p4config.json > /var/log/simple_switch.log 2>&1"
  sleep 3; docker exec p4-central-sede1 pgrep -x simple_switch >/dev/null || print_error "simple_switch central1 no arranco"
  local tin tout; tin=$(get_mac p4-central-sede1 p4c1-tun-in); tout=$(get_mac p4-central-sede1 p4c1-tun-out)
  run_p4_cli "p4-central-sede1" "9091" "
table_add from_access_geneve rewrite_geneve_and_forward ${TLV_HOSTS}&&&0xFFFFFFFF 0 0x0800 => 2 ${tin} ${tout} $(ip2hex ${BCG1_IP}) $(ip2hex ${BCG2_IP}) 100
table_add from_access_geneve decap_geneve_ipv4_to_mpls ${TLV_PHONES}&&&0xFFFFFFFF 0 0x0800 => 1 100
table_add from_access_geneve decap_geneve_arp_to_mpls ${TLV_ARP}&&&0xFFFFFFFF 0 0x0806 => 1 100
table_add from_access_geneve decap_geneve_ipv4_to_mpls ${TLV_INTERNET}&&&0xFFFFFFFF 0 0x0800 => 2 100
table_add from_access_geneve decap_geneve_arp_to_mpls ${TLV_INTERNET}&&&0xFFFFFFFF 0 0x0806 => 2 100
"
  print_info "Central1 desplegada"
}

deploy_central2(){
  print_header "Desplegando Central P4 - SEDE 2"
  for p in p4c2-access p4c2-mpls p4c2-isp; do ovs-vsctl --if-exists del-port $p 2>/dev/null || true; done
  create_container "p4-central-sede2" "172.16.0.12"; install_tools "p4-central-sede2" "wireguard-tools"
  attach_ovs "p4-central-sede2" "p4c2-access" "AccessNet2" "${CENTRAL2_IP}"
  attach_ovs "p4-central-sede2" "p4c2-mpls" "MplsWan" ""
  attach_ovs "p4-central-sede2" "p4c2-isp" "ExtNet2" "${CENTRAL2_ISP_IP}"
  create_internal_veth "p4-central-sede2" "p4c2-tun-in" "p4c2-tun-out"
  common_central_kernel_config "p4-central-sede2" "p4c2-tun-out" "p4c2-isp" "${CENTRAL2_ISP_IP}" "${CENTRAL2_ISP_GW}" "10.20.2.0/24" "${BCG2_IP}" "02:00:00:00:02:03" "${BCG1_IP}" "${WG_PUB_SEDE1}" "${CENTRAL1_ISP_IP}" "${WG_C2_IP}" "${WG_PRIV_SEDE2}"
  docker cp "$P4_CENTRAL_CONFIG" p4-central-sede2:/tmp/p4config.json
  docker exec -d p4-central-sede2 bash -c "simple_switch -i 0@p4c2-access -i 1@p4c2-mpls -i 2@p4c2-tun-in --thrift-port 9092 --log-console /tmp/p4config.json > /var/log/simple_switch.log 2>&1"
  sleep 3; docker exec p4-central-sede2 pgrep -x simple_switch >/dev/null || print_error "simple_switch central2 no arranco"
  local tin tout; tin=$(get_mac p4-central-sede2 p4c2-tun-in); tout=$(get_mac p4-central-sede2 p4c2-tun-out)
  run_p4_cli "p4-central-sede2" "9092" "
table_add from_access_geneve rewrite_geneve_and_forward ${TLV_HOSTS}&&&0xFFFFFFFF 0 0x0800 => 2 ${tin} ${tout} $(ip2hex ${BCG2_IP}) $(ip2hex ${BCG1_IP}) 100
table_add from_access_geneve decap_geneve_ipv4_to_mpls ${TLV_PHONES}&&&0xFFFFFFFF 0 0x0800 => 1 100
table_add from_access_geneve decap_geneve_arp_to_mpls ${TLV_ARP}&&&0xFFFFFFFF 0 0x0806 => 1 100
table_add from_access_geneve decap_geneve_ipv4_to_mpls ${TLV_INTERNET}&&&0xFFFFFFFF 0 0x0800 => 2 100
table_add from_access_geneve decap_geneve_arp_to_mpls ${TLV_INTERNET}&&&0xFFFFFFFF 0 0x0806 => 2 100
"
  print_info "Central2 desplegada"
}

deploy_bcg(){
  local sede=$1 num=$2 lan=$3 cpe_lan=$4 bcg_ip=$5 central_name=$6 central_access=$7 thrift=$8 mgmt_ip=$9
  local name="p4-bcg-${sede}" rport="p4bcg${num}-router" aport="p4bcg${num}-access" cport="p4bcg${num}-cpe" veth_rou="veth-p4bcg${num}-rou" veth_cpe="veth-p4bcg${num}-cpe"
  print_header "Desplegando BCG P4 - ${sede}"
  docker rm -f ${name} 2>/dev/null || true; ovs-vsctl --if-exists del-port ${aport} 2>/dev/null || true
  for v in ${veth_rou} ${veth_cpe} ${rport} ${cport}; do ip link del $v 2>/dev/null || true; done
  create_container "${name}" "${mgmt_ip}"; install_tools "${name}" ""
  attach_linux "${name}" "${rport}" "${lan}" "${veth_rou}"
  attach_linux "${name}" "${cport}" "${cpe_lan}" "${veth_cpe}"
  attach_ovs "${name}" "${aport}" "AccessNet${num}" "${bcg_ip}"
  docker cp "$P4_BCG_CONFIG" ${name}:/tmp/p4config.json
  docker exec -d ${name} bash -c "simple_switch -i 0@${rport} -i 1@${aport} -i 2@${cport} --thrift-port ${thrift} --log-console /tmp/p4config.json > /var/log/simple_switch.log 2>&1"
  sleep 3; docker exec ${name} pgrep -x simple_switch >/dev/null || print_error "simple_switch ${name} no arranco"
  docker exec ${name} iptables -I INPUT 1 -i ${aport} -p udp --dport 6081 -j DROP
  local bcg_mac cen_mac bcg_hex cen_hex
  bcg_mac=$(get_mac ${name} ${aport}); cen_mac=$(get_mac ${central_name} ${central_access})
  if [ "${num}" = "1" ]; then bcg_hex=$(ip2hex ${BCG1_IP}); cen_hex=$(ip2hex ${CENTRAL1_IP}); else bcg_hex=$(ip2hex ${BCG2_IP}); cen_hex=$(ip2hex ${CENTRAL2_IP}); fi
  run_p4_cli "${name}" "${thrift}" "
table_add from_router_ipv4 encap_geneve_ipv4 10.20.1.0/25 0 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} ${TLV_HOSTS}
table_add from_router_ipv4 encap_geneve_ipv4 10.20.1.128/25 0 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} ${TLV_PHONES}
table_add from_router_ipv4 encap_geneve_ipv4 10.20.2.0/25 0 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} ${TLV_HOSTS}
table_add from_router_ipv4 encap_geneve_ipv4 10.20.2.128/25 0 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} ${TLV_PHONES}
table_add from_router_ipv4 encap_geneve_ipv4 10.20.0.254/32 0 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} ${TLV_PHONES}
table_add from_router_ipv4 encap_geneve_ipv4 0.0.0.0/0 2 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} ${TLV_INTERNET}
table_add from_router_arp encap_geneve_arp 0 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} ${TLV_ARP}
table_add from_router_arp encap_geneve_arp 2 => 1 ${bcg_mac} ${cen_mac} ${bcg_hex} ${cen_hex} ${GENEVE_VNI} ${TLV_INTERNET}
table_add from_access_ipv4 decap_geneve_ipv4 ${TLV_HOSTS} 1 => 0
table_add from_access_ipv4 decap_geneve_ipv4 ${TLV_PHONES} 1 => 0
table_add from_access_ipv4 decap_geneve_ipv4 ${TLV_INTERNET} 1 => 2
table_add from_access_arp decap_geneve_arp ${TLV_ARP} 1 => 0
table_add from_access_arp decap_geneve_arp ${TLV_INTERNET} 1 => 2
"
  print_info "BCG${num} desplegado"
}

populate_return_tables(){
  print_header "Poblando tablas de retorno"
  local c1_access c2_access b1_access b2_access
  c1_access=$(get_mac p4-central-sede1 p4c1-access); c2_access=$(get_mac p4-central-sede2 p4c2-access)
  b1_access=$(get_mac p4-bcg-sede1 p4bcg1-access); b2_access=$(get_mac p4-bcg-sede2 p4bcg2-access)
  run_p4_cli "p4-central-sede1" "9091" "
table_add from_wg_geneve rewrite_geneve_and_forward 2 => 0 ${c1_access} ${b1_access} $(ip2hex ${CENTRAL1_IP}) $(ip2hex ${BCG1_IP})
table_add from_mpls_ipv4 encap_mpls_ipv4_to_access 1 => 0 ${c1_access} ${b1_access} $(ip2hex ${CENTRAL1_IP}) $(ip2hex ${BCG1_IP}) ${GENEVE_VNI} ${TLV_PHONES}
table_add from_mpls_arp encap_mpls_arp_to_access 1 => 0 ${c1_access} ${b1_access} $(ip2hex ${CENTRAL1_IP}) $(ip2hex ${BCG1_IP}) ${GENEVE_VNI} ${TLV_ARP}
table_add from_tun_ipv4 encap_mpls_ipv4_to_access 2 => 0 ${c1_access} ${b1_access} $(ip2hex ${CENTRAL1_IP}) $(ip2hex ${BCG1_IP}) ${GENEVE_VNI} ${TLV_INTERNET}
table_add from_tun_arp encap_mpls_arp_to_access 2 => 0 ${c1_access} ${b1_access} $(ip2hex ${CENTRAL1_IP}) $(ip2hex ${BCG1_IP}) ${GENEVE_VNI} ${TLV_INTERNET}
"
  run_p4_cli "p4-central-sede2" "9092" "
table_add from_wg_geneve rewrite_geneve_and_forward 2 => 0 ${c2_access} ${b2_access} $(ip2hex ${CENTRAL2_IP}) $(ip2hex ${BCG2_IP})
table_add from_mpls_ipv4 encap_mpls_ipv4_to_access 1 => 0 ${c2_access} ${b2_access} $(ip2hex ${CENTRAL2_IP}) $(ip2hex ${BCG2_IP}) ${GENEVE_VNI} ${TLV_PHONES}
table_add from_mpls_arp encap_mpls_arp_to_access 1 => 0 ${c2_access} ${b2_access} $(ip2hex ${CENTRAL2_IP}) $(ip2hex ${BCG2_IP}) ${GENEVE_VNI} ${TLV_ARP}
table_add from_tun_ipv4 encap_mpls_ipv4_to_access 2 => 0 ${c2_access} ${b2_access} $(ip2hex ${CENTRAL2_IP}) $(ip2hex ${BCG2_IP}) ${GENEVE_VNI} ${TLV_INTERNET}
table_add from_tun_arp encap_mpls_arp_to_access 2 => 0 ${c2_access} ${b2_access} $(ip2hex ${CENTRAL2_IP}) $(ip2hex ${BCG2_IP}) ${GENEVE_VNI} ${TLV_INTERNET}
"
  print_info "Tablas de retorno completas"
}

verify(){
  print_header "Verificacion"
  docker exec p4-central-sede1 wg show 2>/dev/null | grep -E "peer|handshake|transfer" || true
  docker exec p4-central-sede1 ping -c2 -W2 ${WG_C2_IP} >/dev/null 2>&1 && print_info "Tunel WireGuard operativo" || print_warning "WireGuard sin respuesta aun"
  echo "Pruebas: h1->h2, t1->t2, t1->10.20.0.254, h1/t1->Internet"
}

main(){
  echo -e "${CYAN}\n==========================================\n  SD-WAN P4 - Internet CPE/NAT\n==========================================${NC}"
  setup_wg_keys; check_prerequisites; deploy_central1; deploy_central2
  deploy_bcg "sede1" "1" "lan11" "lan12" "${BCG1_IP}" "p4-central-sede1" "p4c1-access" "9093" "172.16.0.21"
  deploy_bcg "sede2" "2" "lan21" "lan22" "${BCG2_IP}" "p4-central-sede2" "p4c2-access" "9094" "172.16.0.22"
  populate_return_tables; verify; print_info "Despliegue completado"
}
main
