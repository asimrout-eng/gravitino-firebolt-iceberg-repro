#!/usr/bin/env bash
set -e

# Creates an Iceberg namespace + table via the Gravitino REST API.
# Run after Gravitino is ready.
#
# Usage:
#   bash k8s/create-test-data.sh [GRAVITINO_URL]
#
# GRAVITINO_URL defaults to the port-forwarded local address.
# For NLB access, pass the NLB DNS: bash k8s/create-test-data.sh http://<NLB>:9001

NS="gravitino-repro"
DEPLOY="gravitino-iceberg-rest"
GRAV_URL="${1:-}"

CLEANUP_PF=""
cleanup() { [ -n "$CLEANUP_PF" ] && kill "$CLEANUP_PF" 2>/dev/null; }
trap cleanup EXIT

if [ -z "$GRAV_URL" ]; then
  echo "Port-forwarding to Gravitino pod..."
  POD=$(kubectl get pods -n "$NS" -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$POD" ]; then
    echo "ERROR: No Gravitino pod found. Is it deployed?"
    exit 1
  fi
  kubectl port-forward "$POD" 19001:9001 -n "$NS" &
  CLEANUP_PF=$!
  sleep 3
  GRAV_URL="http://localhost:19001"
fi

BASE="${GRAV_URL}/iceberg/v1"

echo "=== Creating test namespace 'repro_test' ==="
curl -sf -X POST "${BASE}/namespaces" \
  -H "Content-Type: application/json" \
  -d '{"namespace": ["repro_test"], "properties": {}}' 2>/dev/null \
  && echo "  Created" \
  || echo "  Already exists (OK)"

echo ""
echo "=== Creating test table 'repro_test.sample_table' ==="
HTTP_CODE=$(curl -s -o /tmp/grav_create_table.json -w "%{http_code}" \
  -X POST "${BASE}/namespaces/repro_test/tables" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "sample_table",
    "schema": {
      "type": "struct",
      "schema-id": 0,
      "fields": [
        {"id": 1, "name": "id", "type": "long", "required": true},
        {"id": 2, "name": "name", "type": "string", "required": false},
        {"id": 3, "name": "created_at", "type": "timestamptz", "required": false}
      ]
    }
  }')

if [ "$HTTP_CODE" = "200" ]; then
  echo "  Created successfully"
elif [ "$HTTP_CODE" = "409" ]; then
  echo "  Already exists (OK)"
else
  echo "  HTTP $HTTP_CODE — check /tmp/grav_create_table.json"
fi

echo ""
echo "=== Verifying: load table with credential vending ==="
RESP=$(curl -s -w "\n%{http_code}" \
  -H "X-Iceberg-Access-Delegation: vended-credentials" \
  "${BASE}/namespaces/repro_test/tables/sample_table" 2>/dev/null)
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

if [ "$CODE" = "200" ]; then
  echo "  Table loaded (HTTP $CODE)"
  echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
cfg = d.get('config', {})
if 's3.access-key-id' in cfg:
    print('  Vended S3 credentials: YES (access key starts with', cfg['s3.access-key-id'][:8] + '...)')
elif cfg:
    print('  Config keys:', list(cfg.keys()))
else:
    print('  No vended credentials in response (credential vending may not be configured)')
" 2>/dev/null || true
else
  echo "  FAILED (HTTP $CODE)"
  echo "$BODY" | head -5
fi

echo ""
echo "=== Test data ready ==="
echo ""
echo "Firebolt SQL:"
echo ""
echo "  SELECT * FROM READ_ICEBERG("
echo "    LOCATION => 'gravitino_eks_test',"
echo "    NAMESPACE => 'repro_test',"
echo "    TABLE => 'sample_table'"
echo "  ) LIMIT 10;"
echo ""
echo "(Table is empty — a successful 0-row result proves the full E2E flow)"
