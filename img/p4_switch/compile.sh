#!/usr/bin/env bash
#==============================================================================
# compile.sh — Compilar programas P4 SD-WAN
#==============================================================================
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

P4DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_info()  { echo -e "${GREEN}[✓]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   SD-WAN P4 — Compilación            ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"

cd ${P4DIR}
command -v p4c &>/dev/null || print_error "p4c no instalado"

for prog in bcg_switch central_switch; do
    [ -f "${prog}.p4" ] || print_error "${prog}.p4 no existe en ${P4DIR}"
    echo "Compilando ${prog}.p4..."
    rm -rf ${prog}.json
    p4c --target bmv2 --arch v1model \
        --p4runtime-files ${prog}.p4info.txt \
        -o ${prog}.json \
        ${prog}.p4
    print_info "${prog}.json/${prog}.json generado"
done

echo ""
print_info "Compilación completada"
