#!/bin/bash

echo "════════════════════════════════════════"
echo "  Destruyendo P4 Switch Sede 2"
echo "════════════════════════════════════════"

# Eliminar contenedor
echo "[*] Eliminando contenedor p4-switch-sede2..."
docker stop p4-switch-sede2 2>/dev/null
docker rm -f p4-switch-sede2 2>/dev/null
echo "[✓] Contenedor eliminado"

# Eliminar interfaces veth del host
echo "[*] Eliminando interfaces..."
for iface in p4s2-accessnet2 p4s2-mpls; do
    ip link set "$iface" down 2>/dev/null
    ip link delete "$iface" 2>/dev/null
    echo "[✓] Interfaz $iface eliminada"
done

# Desconectar y eliminar VXLAN
echo "[*] Eliminando VXLAN2..."
ip link set vxlan2 down 2>/dev/null
ip link delete vxlan2 2>/dev/null
echo "[✓] VXLAN2 eliminado"

# Limpiar puertos huérfanos de OVS
echo "[*] Limpiando puertos OVS huérfanos..."
ovs-vsctl --if-exists del-port AccessNet2 p4s2-accessnet2 2>/dev/null
ovs-vsctl --if-exists del-port MplsWan p4s2-mpls 2>/dev/null
ovs-vsctl --if-exists del-port AccessNet2 vxlan2 2>/dev/null
echo "[✓] Puertos OVS limpiados"

echo ""
echo "[✓] Destrucción completada"