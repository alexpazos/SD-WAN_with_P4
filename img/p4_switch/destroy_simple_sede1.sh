#!/bin/bash

echo "════════════════════════════════════════"
echo "  Destruyendo P4 Switch Sede 1"
echo "════════════════════════════════════════"

# Eliminar contenedor
echo "[*] Eliminando contenedor p4-switch-sede1..."
docker stop p4-switch-sede1 2>/dev/null
docker rm -f p4-switch-sede1 2>/dev/null
echo "[✓] Contenedor eliminado"

# Eliminar interfaces veth del host
echo "[*] Eliminando interfaces..."
for iface in p4s1-accessnet1 p4s1-mpls; do
    ip link set "$iface" down 2>/dev/null
    ip link delete "$iface" 2>/dev/null
    echo "[✓] Interfaz $iface eliminada"
done

# Desconectar y eliminar VXLAN
echo "[*] Eliminando VXLAN1..."
ip link set vxlan1 down 2>/dev/null
ip link delete vxlan1 2>/dev/null
echo "[✓] VXLAN1 eliminado"

# Limpiar puertos huérfanos de OVS
echo "[*] Limpiando puertos OVS huérfanos..."
ovs-vsctl --if-exists del-port AccessNet1 p4s1-accessnet1 2>/dev/null
ovs-vsctl --if-exists del-port MplsWan p4s1-mpls 2>/dev/null
ovs-vsctl --if-exists del-port AccessNet1 vxlan1 2>/dev/null
echo "[✓] Puertos OVS limpiados"

echo ""
echo "[✓] Destrucción completada"