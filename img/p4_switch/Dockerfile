FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Instalar dependencias básicas
RUN apt-get update && apt-get install -y \
    git wget curl \
    build-essential cmake autoconf automake libtool pkg-config \
    python3 python3-pip \
    iproute2 iputils-ping net-tools tcpdump iptables \
    nano vim \
    && rm -rf /var/lib/apt/lists/*

# Dependencias de P4
RUN apt-get update && apt-get install -y \
    libboost-dev libboost-filesystem-dev libboost-program-options-dev \
    libboost-thread-dev libboost-test-dev \
    libevent-dev libnanomsg-dev libgmp-dev libpcap-dev libssl-dev \
    protobuf-compiler libprotobuf-dev \
    && rm -rf /var/lib/apt/lists/*

    
# Instalar behavioral-model (bmv2)
WORKDIR /opt
RUN git clone https://github.com/p4lang/behavioral-model.git
WORKDIR /opt/behavioral-model
RUN ./autogen.sh && \
    ./configure --without-nanomsg --without-thrift && \
    make -j$(nproc) && \
    make install && \
    ldconfig

# Instalar p4c (compilador P4)
WORKDIR /opt
RUN git clone --recursive https://github.com/p4lang/p4c.git
WORKDIR /opt/p4c/build
RUN cmake .. && make -j$(nproc) && make install && ldconfig

# Crear directorio de trabajo
WORKDIR /root/p4
RUN mkdir -p /root/p4/compiled

# Copiar programa P4
COPY p4src/sdwan-unified.p4 /root/p4/

# El switch se inicia mediante el comando en Terraform
EXPOSE 9559

CMD ["sleep", "infinity"]
