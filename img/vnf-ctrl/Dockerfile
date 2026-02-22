FROM osrg/ryu

RUN apt-get clean
RUN	apt-get update && apt-get install -y \
	net-tools \
	iproute \
	inetutils-ping \
    openvswitch-switch \
    openvswitch-common \
    iperf \
    tcpdump \
    git

COPY qos_simple_switch_13.py /root/qos_simple_switch_13.py 
COPY README.txt README.txt
RUN git clone https://github.com/martimy/flowmanager /root/flowmanager




