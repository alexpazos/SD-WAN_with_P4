#!/usr/bin/env bash
set -e

echo "[*] Limpiando contenedor previo del switch..."
docker rm -f s1 2>/dev/null || true

echo "[*] Creando red bridge interna solo para el switch..."
docker network rm p4net 2>/dev/null || true
docker network create --subnet=172.16.0.0/24 p4net

echo "[*] Lanzando switch P4 en background (sin interfaces, se añadirán después)..."
docker run -d --rm \
  --name s1 \
  --network p4net \
  --ip 172.16.0.254 \
  --privileged \
  --cap-add=NET_ADMIN \
  -v $(pwd)/basic.json:/tmp/basic.json \
  p4lang/behavioral-model \
  bash -c "tail -f /dev/null"

echo "[*] Instalando herramientas de red en el switch..."
docker exec s1 bash -c "apt-get update -qq && apt-get install -y -qq iproute2 net-tools tcpdump" 2>/dev/null

echo "[+] Esperando a que el switch arranque..."
sleep 3

echo "[+] Switch P4 arrancado correctamente"
echo "[+] Red de gestión: 172.16.0.254"
echo "[+] Para ver logs: docker logs -f s1"
echo "[+] Para conectarte al CLI:"
echo "    docker exec -it s1 simple_switch_CLI --thrift-port 9090"