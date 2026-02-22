#!/bin/bash

echo 'Deploying containerlab Internet scenario...'

sudo ovs-vsctl --may-exist add-br Internet
sudo ovs-vsctl --may-exist add-br ExtNet1
sudo ovs-vsctl --may-exist add-br ExtNet2
sudo mkdir -p /tmp/.clab
sudo curl -L -s https://raw.githubusercontent.com/educaredes/terraform-sdwan/refs/heads/main/clab/isp1.cfg -o /tmp/.clab/isp1.cfg
sudo curl -L -s https://raw.githubusercontent.com/educaredes/terraform-sdwan/refs/heads/main/clab/isp2.cfg -o /tmp/.clab/isp2.cfg
sudo containerlab deploy --topo https://raw.githubusercontent.com/educaredes/terraform-sdwan/refs/heads/main/clab/sdedge-nfv-internet.yaml

echo 'Done!'

echo ''
echo ''

echo 'Configuring client "s1" container...'

sudo docker exec -it clab-sdedge-nfv-internet-s1 ifconfig eth1 10.100.3.3 netmask 255.255.255.0
sudo docker exec -it clab-sdedge-nfv-internet-s1 ip route add 10.100.1.0/24 via 10.100.3.1 dev eth1
sudo docker exec -it clab-sdedge-nfv-internet-s1 ip route add 10.100.2.0/24 via 10.100.3.2 dev eth1
sudo docker exec -it clab-sdedge-nfv-internet-s1 ip route del default via 172.20.20.1 dev eth0
sudo docker exec -it clab-sdedge-nfv-internet-s1 ip route add default via 10.100.3.1 dev eth1
echo 'Done!'

echo ''
echo ''

echo 'Configuring NAT for isp1 router...'

sudo ip addr add 10.0.0.2/30 dev isp1_e1-1
sudo ip link set dev isp1_e1-1 up
sudo ip route add 10.100.1.0/24 via 10.0.0.1 dev isp1_e1-1
sudo ip route add 10.100.3.0/24 via 10.0.0.1 dev isp1_e1-1
sudo vnx_config_nat isp1_e1-1 $(ip route | grep default | cut -d" " -f 5)

echo 'Done!'

echo ''
echo ''

echo 'Configuring NAT for isp2 router...'

sudo ip addr add 10.0.0.6/30 dev isp2_e1-1
sudo ip link set dev isp2_e1-1 up
sudo ip route add 10.100.2.0/24 via 10.0.0.5 dev isp2_e1-1
sudo vnx_config_nat isp2_e1-1 $(ip route | grep default | cut -d" " -f 5)

echo 'Done!'

echo ''
echo ''

echo 'Opening consoles...'

./sdw-clab-consoles.sh open

echo 'Done!'

echo ''
echo ''

echo 'All done!'