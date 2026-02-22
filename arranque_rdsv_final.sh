#!/bin/bash
set -e

echo "==============================================="
echo "RDSV RETO FINAL"
echo "==============================================="

BASE_DIR="$HOME/terraform-sdwan"
ENV_FILE="$BASE_DIR/basrc"

echo
echo "Preparando el entorno"

cd "$BASE_DIR/bin"

./final-prepare-k8slab


# Forzar carga interactiva de bashrc y capturar SDWNS
SDWNS="$(bash -i -c 'echo "$SDWNS"' 2>/dev/null)"

if [ -z "$SDWNS" ]; then
  echo "ERROR: La variable SDWNS no está definida correctamente"
  echo "Valor actual: '$SDWNS'"
  exit 1
fi

if [ "$SDWNS" != "rdsv" ]; then
  echo "ERROR: La variable SDWNS no tiene el valor esperado"
  echo "Valor actual: '$SDWNS'"
  exit 1
fi

export SDWNS
echo "SDWNS configurado correctamente: $SDWNS"

echo
echo "Comprobando Open vSwitch"
sudo ovs-vsctl show

echo
echo "Comprobando Network Attachment Definitions (Multus)"
kubectl get -n "$SDWNS" network-attachment-definitions


cd "$BASE_DIR/vnx"
sudo vnx -f sdedge_nfv_sedes.xml -t 

echo
echo "Escenario VNX desplegado"


cd "$BASE_DIR"
./despliegue_clab.sh

echo
echo "Containerlab desplegado"

echo
echo "==============================================="
echo "Escenario RDSV iniciado correctamente"
echo "==============================================="
