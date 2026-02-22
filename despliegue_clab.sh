#!/bin/bash
set -e

GNMI_USER="admin"
GNMI_PASS="NokiaSrl1!"
GNMI_PORT="57400"

CLAB_DIR="$HOME/terraform-sdwan/clab"

echo "Desplegando escenario con Containerlab..."

sudo ovs-vsctl --may-exist add-br Internet
sudo ovs-vsctl --may-exist add-br ExtNet1
sudo ovs-vsctl --may-exist add-br ExtNet2

sudo mkdir -p /tmp/.clab
sudo curl -L -s https://raw.githubusercontent.com/educaredes/terraform-sdwan/refs/heads/main/clab/isp1.cfg -o /tmp/.clab/isp1.cfg
sudo curl -L -s https://raw.githubusercontent.com/educaredes/terraform-sdwan/refs/heads/main/clab/isp2.cfg -o /tmp/.clab/isp2.cfg

sudo containerlab deploy --topo https://raw.githubusercontent.com/educaredes/terraform-sdwan/refs/heads/main/clab/sdedge-nfv-internet.yaml --reconfigure

echo "Listo!"
echo

#######################################
# Configuración de s1
#######################################
echo "Configurando s1..."

sudo docker exec clab-sdedge-nfv-internet-s1 \
  ifconfig eth1 10.100.3.3 netmask 255.255.255.0

sudo docker exec clab-sdedge-nfv-internet-s1 \
  ip route add 10.100.1.0/24 via 10.100.3.1 dev eth1

sudo docker exec clab-sdedge-nfv-internet-s1 \
  ip route add 10.100.2.0/24 via 10.100.3.2 dev eth1

sudo docker exec clab-sdedge-nfv-internet-s1 \
  ip route del default via 172.20.20.1 dev eth0

sudo docker exec clab-sdedge-nfv-internet-s1 \
  ip route add default via 10.100.3.1 dev eth1

echo "s1 configurado"
echo

#######################################
# Variables gNMI ISP1
#######################################
cat > /tmp/isp1_extnet1.json <<EOF
{
  "IF_NAME": "ethernet-1/1",
  "IF_IP_PREFIX": "10.100.1.254/24"
}
EOF

cat > /tmp/isp1_internet.json <<EOF
{
  "IF_NAME": "ethernet-1/2",
  "IF_IP_PREFIX": "10.100.3.1/24"
}
EOF

cat > /tmp/isp1_route.json <<EOF
{
  "Name_NextHop": "NH_to_ISP2",
  "IP_NextHop": "10.100.3.2",
  "Target_IP_Prefix": "10.100.2.0/24"
}
EOF

#######################################
# Configuración ISP1 vía gNMI
#######################################
echo "Configurando ISP1 via gNMI..."

gnmic -a clab-sdedge-nfv-internet-isp1:${GNMI_PORT} \
  -u ${GNMI_USER} -p ${GNMI_PASS} \
  --skip-verify \
  set \
  --request-file ${CLAB_DIR}/configure_ip_address.yaml \
  --request-vars /tmp/isp1_extnet1.json

gnmic -a clab-sdedge-nfv-internet-isp1:${GNMI_PORT} \
  -u ${GNMI_USER} -p ${GNMI_PASS} \
  --skip-verify \
  set \
  --request-file ${CLAB_DIR}/configure_ip_address.yaml \
  --request-vars /tmp/isp1_internet.json

gnmic -a clab-sdedge-nfv-internet-isp1:${GNMI_PORT} \
  -u ${GNMI_USER} -p ${GNMI_PASS} \
  --skip-verify \
  set \
  --request-file ${CLAB_DIR}/configure_ip_routing.yaml \
  --request-vars /tmp/isp1_route.json

sudo ip addr add 10.0.0.2/30 dev isp1_e1-1
sudo ip link set dev isp1_e1-1 up
sudo ip route add 10.100.1.0/24 via 10.0.0.1 dev isp1_e1-1
sudo ip route add 10.100.3.0/24 via 10.0.0.1 dev isp1_e1-1
sudo vnx_config_nat isp1_e1-1 $(ip route | grep default | cut -d" " -f 5)

echo "ISP1 configurado"


#######################################
# Variables gNMI ISP2
#######################################
cat > /tmp/isp2_extnet2.json <<EOF
{
  "IF_NAME": "ethernet-1/1",
  "IF_IP_PREFIX": "10.100.2.254/24"
}
EOF

cat > /tmp/isp2_internet.json <<EOF
{
  "IF_NAME": "ethernet-1/2",
  "IF_IP_PREFIX": "10.100.3.2/24"
}
EOF

cat > /tmp/isp2_route.json <<EOF
{
  "Name_NextHop": "NH_to_ISP1",
  "IP_NextHop": "10.100.3.1",
  "Target_IP_Prefix": "10.100.1.0/24"
}
EOF

#######################################
# Configuración ISP2 vía gNMI
#######################################
echo "Configurando ISP2 via gNMI..."

gnmic -a clab-sdedge-nfv-internet-isp2:${GNMI_PORT} \
  -u ${GNMI_USER} -p ${GNMI_PASS} \
  --skip-verify \
  set \
  --request-file ${CLAB_DIR}/configure_ip_address.yaml \
  --request-vars /tmp/isp2_extnet2.json

gnmic -a clab-sdedge-nfv-internet-isp2:${GNMI_PORT} \
  -u ${GNMI_USER} -p ${GNMI_PASS} \
  --skip-verify \
  set \
  --request-file ${CLAB_DIR}/configure_ip_address.yaml \
  --request-vars /tmp/isp2_internet.json

gnmic -a clab-sdedge-nfv-internet-isp2:${GNMI_PORT} \
  -u ${GNMI_USER} -p ${GNMI_PASS} \
  --skip-verify \
  set \
  --request-file ${CLAB_DIR}/configure_ip_routing.yaml \
  --request-vars /tmp/isp2_route.json

sudo ip addr add 10.0.0.6/30 dev isp2_e1-1
sudo ip link set dev isp2_e1-1 up
sudo ip route add 10.100.2.0/24 via 10.0.0.5 dev isp2_e1-1
sudo vnx_config_nat isp2_e1-1 $(ip route | grep default | cut -d" " -f 5)

echo "ISP2 configurado"


#######################################
# Consolas
#######################################
./clab/sdw-clab-consoles.sh open


echo "Terminado!"
