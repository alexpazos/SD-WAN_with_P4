#!/usr/bin/env bash
#==============================================================================
# Script de diagnóstico - Verificar variables de entorno
#==============================================================================

echo "=========================================="
echo "DIAGNÓSTICO DE VARIABLES DE ENTORNO"
echo "=========================================="
echo ""

echo "1. Variable P4_CONFIG en el script:"
echo "   P4_CONFIG = '$P4_CONFIG'"
echo ""

echo "2. ¿Está definida?"
if [ -n "$P4_CONFIG" ]; then
    echo "   ✓ SÍ está definida"
else
    echo "   ✗ NO está definida"
fi
echo ""

echo "3. ¿El archivo existe?"
if [ -f "$P4_CONFIG" ]; then
    echo "   ✓ SÍ existe: $P4_CONFIG"
    ls -lh "$P4_CONFIG"
else
    echo "   ✗ NO existe o ruta incorrecta: $P4_CONFIG"
fi
echo ""

echo "4. Usuario actual:"
echo "   $(whoami)"
echo ""

echo "5. UID efectivo:"
echo "   EUID = $EUID"
echo ""

echo "6. Todas las variables que contienen 'P4':"
env | grep P4 || echo "   Ninguna variable con 'P4'"
echo ""

echo "=========================================="
