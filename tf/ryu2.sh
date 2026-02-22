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
NAMESPACE="rdsv"

################  Verificaciones previas ######################
command -v curl >/dev/null || { echo "  curl no encontrado"; exit 1; }

################  SITE 1 ######################################
SITE="site1"
APP_LABEL="vnf-ctrl-${SITE}"
SVC="vnf-ctrl-${SITE}-service"
echo -e "\n═══════════════  Cargando reglas en ${SITE}  ═══════════════"

######## Esperar a que el Pod Ryu esté Ready ############
echo "...Esperando Pod Ryu (${APP_LABEL})..."
$KCTL wait --for=condition=ready pod -l "k8s-app=${APP_LABEL}" -n "$NAMESPACE" --timeout=120s

######## Acceso por NodePort #########
NODEPORT="$($KCTL get svc -n "$NAMESPACE" "$SVC" -o jsonpath='{.spec.ports[?(@.name=="ryu-rest")].nodePort}')"
[[ -n "$NODEPORT" ]] || { echo "  No se pudo obtener NodePort de $SVC"; exit 1; }

RYU_ROOT="http://localhost:${NODEPORT}/stats"
FLOW_URL="${RYU_ROOT}/flowentry/add"
echo "🎯 Endpoint REST (NodePort) = ${FLOW_URL}"

######## Esperar datapaths 1, 2 y 3 en Ryu ###############
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
if [[ "$COUNT" -lt 3 ]]; then
  echo "   ⚠️ ADVERTENCIA: Solo $COUNT switches conectados, se esperaban 3"
fi

######## Configurar colas QoS en OVS ####################
echo "⚙️  Configurando colas QoS"
$KCTL -n "$NAMESPACE" exec "vnf-access-$SITE" -- sh -c '
  ovs-vsctl \
    -- --id=@q0 create Queue other-config:max-rate=3600000 \
    -- --id=@q1 create Queue other-config:min-rate=2200000 \
    -- --id=@qos create QoS type=linux-htb other-config:max-rate=3600000 queues:0=@q0 queues:1=@q1 \
    -- set Port axswan qos=@qos
' && echo "  ✅ Colas QoS creadas" || echo "  ⚠️ Error al crear colas QoS"

######## Enviar reglas de flujo ####################
echo "📤 Enviando reglas de flujo..."

echo "➜ from-cpe"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 3, "priority": 40000, "cookie": 2, "match": {"in_port": 3}, "actions": [{"type":"OUTPUT", "port":1}]}' "$FLOW_URL"

echo "➜ to-cpe"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 3, "priority": 40000, "cookie": 1, "match": {"in_port": 1}, "actions": [{"type":"OUTPUT", "port":3}]}' "$FLOW_URL"

echo "➜ broadcast-from-axs"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 3, "priority": 45000, "cookie": 202001, "match": {"in_port": 1, "dl_dst": "ff:ff:ff:ff:ff:ff"}, "actions": [{"type":"OUTPUT", "port":"FLOOD"}]}' "$FLOW_URL"

echo "➜ from-mpls"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 3, "priority": 45001, "cookie": 202002, "match": {"in_port": 2}, "actions": [{"type":"OUTPUT", "port":1}]}' "$FLOW_URL"

echo "➜ to-voip-gw"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 3, "priority": 45001, "cookie": 202003, "match": {"in_port": 1, "dl_dst": "00:00:00:00:00:20"}, "actions": [{"type":"OUTPUT", "port":2}]}' "$FLOW_URL"

echo "➜ access-wan"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 1,"priority": 40000, "match": {"in_port": 1}, "actions": [{"type":"OUTPUT", "port":2}]}' "$FLOW_URL"

echo "➜ wan-access"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 1,"priority": 40000, "match": {"in_port": 2}, "actions": [{"type":"OUTPUT", "port":1}]}' "$FLOW_URL"

echo "➜ cpe-wan"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 2,"priority": 40000, "match": {"in_port": 2}, "actions": [{"type":"OUTPUT", "port":1}]}' "$FLOW_URL"

echo "➜ wan-cpe"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 2,"priority": 40000, "match": {"in_port": 1}, "actions": [{"type":"OUTPUT", "port":2}]}' "$FLOW_URL"

echo "➜ qos-regla"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 1, "priority": 50000, "match": {"in_port": 1, "eth_type": 2048, "ip_proto": 17, "udp_dst": 5005}, "actions": [{"type": "SET_QUEUE", "queue_id": 1}, {"type": "OUTPUT", "port": 2}]}' "$FLOW_URL"

echo "  ✅ Reglas cargadas en ${SITE}"

######## Abrir FlowManager GUI ############
GUI_URL="http://localhost:${NODEPORT}/home/index.html"
echo "🌐 Abriendo FlowManager GUI en ${GUI_URL}"
firefox "$GUI_URL" &


################  SITE 2 ######################################
SITE="site2"
APP_LABEL="vnf-ctrl-${SITE}"
SVC="vnf-ctrl-${SITE}-service"
echo -e "\n═══════════════  Cargando reglas en ${SITE}  ═══════════════"

######## Esperar a que el Pod Ryu esté Ready ############
echo "...Esperando Pod Ryu (${APP_LABEL})..."
$KCTL wait --for=condition=ready pod -l "k8s-app=${APP_LABEL}" -n "$NAMESPACE" --timeout=120s

######## Acceso por NodePort #########
NODEPORT="$($KCTL get svc -n "$NAMESPACE" "$SVC" -o jsonpath='{.spec.ports[?(@.name=="ryu-rest")].nodePort}')"
[[ -n "$NODEPORT" ]] || { echo "  No se pudo obtener NodePort de $SVC"; exit 1; }

RYU_ROOT="http://localhost:${NODEPORT}/stats"
FLOW_URL="${RYU_ROOT}/flowentry/add"
echo "🎯 Endpoint REST (NodePort) = ${FLOW_URL}"

######## Esperar datapaths 1, 2 y 3 en Ryu ###############
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
if [[ "$COUNT" -lt 3 ]]; then
  echo "   ⚠️ ADVERTENCIA: Solo $COUNT switches conectados, se esperaban 3"
fi

######## Configurar colas QoS en OVS ####################
echo "⚙️  Configurando colas QoS"
$KCTL -n "$NAMESPACE" exec "vnf-access-$SITE" -- sh -c '
  ovs-vsctl \
    -- --id=@q0 create Queue other-config:max-rate=3600000 \
    -- --id=@q1 create Queue other-config:min-rate=2200000 \
    -- --id=@qos create QoS type=linux-htb other-config:max-rate=3600000 queues:0=@q0 queues:1=@q1 \
    -- set Port axswan qos=@qos
' && echo "  ✅ Colas QoS creadas" || echo "  ⚠️ Error al crear colas QoS"

######## Enviar reglas de flujo ####################
echo "📤 Enviando reglas de flujo..."

echo "➜ from-cpe"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 3, "priority": 40000, "cookie": 2, "match": {"in_port": 3}, "actions": [{"type":"OUTPUT", "port":1}]}' "$FLOW_URL"

echo "➜ to-cpe"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 3, "priority": 40000, "cookie": 1, "match": {"in_port": 1}, "actions": [{"type":"OUTPUT", "port":3}]}' "$FLOW_URL"

echo "➜ broadcast-from-axs"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 3, "priority": 45000, "cookie": 202001, "match": {"in_port": 1, "dl_dst": "ff:ff:ff:ff:ff:ff"}, "actions": [{"type":"OUTPUT", "port":"FLOOD"}]}' "$FLOW_URL"

echo "➜ from-mpls"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 3, "priority": 45001, "cookie": 202002, "match": {"in_port": 2}, "actions": [{"type":"OUTPUT", "port":1}]}' "$FLOW_URL"

echo "➜ to-voip-gw"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 3, "priority": 45001, "cookie": 202003, "match": {"in_port": 1, "dl_dst": "00:00:00:00:00:20"}, "actions": [{"type":"OUTPUT", "port":2}]}' "$FLOW_URL"

echo "➜ access-wan"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 1,"priority": 40000, "match": {"in_port": 1}, "actions": [{"type":"OUTPUT", "port":2}]}' "$FLOW_URL"

echo "➜ wan-access"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 1,"priority": 40000, "match": {"in_port": 2}, "actions": [{"type":"OUTPUT", "port":1}]}' "$FLOW_URL"

echo "➜ cpe-wan"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 2,"priority": 40000, "match": {"in_port": 2}, "actions": [{"type":"OUTPUT", "port":1}]}' "$FLOW_URL"

echo "➜ wan-cpe"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 2,"priority": 40000, "match": {"in_port": 1}, "actions": [{"type":"OUTPUT", "port":2}]}' "$FLOW_URL"

echo "➜ qos-regla"
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -X POST -d '{"dpid": 1, "priority": 50000, "match": {"in_port": 1, "eth_type": 2048, "ip_proto": 17, "udp_dst": 5005}, "actions": [{"type": "SET_QUEUE", "queue_id": 1}, {"type": "OUTPUT", "port": 2}]}' "$FLOW_URL"

echo "  ✅ Reglas cargadas en ${SITE}"

######## Abrir FlowManager GUI ############
GUI_URL="http://localhost:${NODEPORT}/home/index.html"
echo "🌐 Abriendo FlowManager GUI en ${GUI_URL}"
firefox "$GUI_URL" &

echo -e "\n✅ Todas las reglas SDN se han inyectado con éxito"

exit 0