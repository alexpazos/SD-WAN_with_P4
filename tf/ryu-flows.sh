#!/usr/bin/env bash
set -euo pipefail

################  Resolver cliente K8s ########################
if command -v kubectl >/dev/null 2>&1; then
  KCTL="kubectl"
elif command -v microk8s >/dev/null 2>&1; then
  KCTL="sudo microk8s kubectl"
else
  echo "  No se encontró ni kubectl ni microk8s" >&2; exit 1
fi
echo "  Cliente K8s = $KCTL"

################  Configuración ###############################
JSON_DIR="../json"     # carpeta con los .json
NAMESPACE="rdsv"                               # namespace de los Pods
COMMON_JSONS=(
  from-cpe.json
  to-cpe.json
  broadcast-from-axs.json
  from-mpls.json
  to-voip-gw.json
  access-wan.json
  wan-access.json
  cpe-wan.json
  wan-cpe.json
  qos-regla.json
)

################  Verificaciones previas ######################
[[ -d "$JSON_DIR" ]] || { echo "  Carpeta $JSON_DIR no existe"; exit 1; }
command -v curl >/dev/null || { echo "  curl no encontrado"; exit 1; }

################  Detectar sites sdedgeN ######################
mapfile -t EDGE_DIRS < <(find "$JSON_DIR" -maxdepth 1 -type d -name 'sdedge*' | sort)
[[ ${#EDGE_DIRS[@]} -gt 0 ]] || { echo "  No se encontraron sdedge*"; exit 1; }

echo "🔎 Sites detectados: ${EDGE_DIRS[*]##*/}"

################  Bucle principal por site ####################
for EDGE_DIR in "${EDGE_DIRS[@]}"; do
  NETNUM=$(basename "$EDGE_DIR" | sed 's/^sdedge//')   # 1, 2, …
  SITE="site${NETNUM}"                                 # site1, site2, …
  APP_LABEL="vnf-ctrl-${SITE}"                          # label del Pod
  SVC="vnf-ctrl-${SITE}-service"                        # Service (8080)
  echo -e "\n═══════════════  Cargando reglas en ${SITE}  ═══════════════"

  ######## 1) Esperar a que el Pod Ryu esté Ready ############
  echo "...Esperando Pod Ryu (${APP_LABEL})..."
  $KCTL wait --for=condition=ready pod -l "k8s-app=${APP_LABEL}" \
      -n "$NAMESPACE" --timeout=120s

  ######## 2) Acceso por NodePort #########
  NODEPORT="$($KCTL get svc -n "$NAMESPACE" "$SVC" \
    -o jsonpath='{.spec.ports[?(@.name=="ryu-rest")].nodePort}')"
  [[ -n "$NODEPORT" ]] || { echo "  No se pudo obtener NodePort de $SVC"; exit 1; }

  # Construir URL base
  RYU_ROOT="http://localhost:${NODEPORT}/stats"
  FLOW_URL="${RYU_ROOT}/flowentry/add"
  echo "🎯 Endpoint REST (NodePort) = ${FLOW_URL}"

 ######## 3) Esperar datapaths 1, 2 y 3 en Ryu ###############
echo "   Esperando switches conectados a Ryu..."
for i in {1..20}; do
  SWITCHES=$(curl -sf "${RYU_ROOT}/switches" 2>/dev/null || echo "[]")
  COUNT=$(echo "$SWITCHES" | jq 'length' 2>/dev/null || echo 0)
  
  if [[ "$COUNT" -ge 3 ]]; then
    echo "   ✅ $COUNT switches detectados:  $SWITCHES"
    break
  fi
  
  echo "   Switches detectados: $COUNT/3 ($i/20)"
  sleep 3
done

# Verificar que tenemos los 3 switches
if [[ "$COUNT" -lt 3 ]]; then
  echo "   ⚠️ ADVERTENCIA: Solo $COUNT switches conectados, se esperaban 3"
fi

  ######## 4) Configurar colas QoS en OVS ####################
  echo "⚙️  Configurando colas QoS"
  $KCTL -n "$NAMESPACE" exec "vnf-access-$SITE" -- sh -c '
    ovs-vsctl \
      -- --id=@q0 create Queue other-config:max-rate=3600000 \
      -- --id=@q1 create Queue other-config:min-rate=2200000 \
      -- --id=@qos create QoS type=linux-htb other-config:max-rate=3600000 queues:0=@q0 queues:1=@q1 \
      -- set Port axswan qos=@qos
  ' && echo "  ✅ Colas QoS creadas" || echo "  ⚠️ Error al crear colas QoS"

  ######## 5) Construir lista de JSON a enviar ###############
  FILES=()
  for f in "${COMMON_JSONS[@]}"; do FILES+=("${JSON_DIR}/${f}"); done
  SPEC_JSON="${EDGE_DIR}/to-voip.json"
  [[ -f "$SPEC_JSON" ]] && FILES+=("$SPEC_JSON") \
    || echo "  $(basename "$SPEC_JSON") no encontrado, se omite"

  ######## 6) Enviar los JSON uno a uno ######################
  for FILE in "${FILES[@]}"; do
    [[ -f "$FILE" ]] || { echo "  $FILE no existe, se salta"; continue; }
    echo "➜ $(basename "$FILE")"
    code=$(curl -s -o /dev/null -w '%{http_code}' \
              -H 'Content-Type: application/json' \
              -X POST -d @"$FILE" "$FLOW_URL")
    if [[ "$code" != 200 ]]; then
      echo "  Error HTTP $code al enviar $(basename "$FILE"); abortando"; exit 1
    fi
  done

  echo "  ✅ Reglas cargadas en ${SITE}"


  ######## 7) Abrir FlowManager GUI ############
  GUI_URL="http://localhost:${NODEPORT}/home/index.html"
  echo "Abriendo FlowManager GUI en ${GUI_URL}"
  firefox "$GUI_URL" &
done

echo -e "\n  Todas las reglas SDN se han inyectado con éxito"

exit 0
