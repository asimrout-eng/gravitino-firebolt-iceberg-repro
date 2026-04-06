#!/usr/bin/env bash
set -e

# ─────────────────────────────────────────────────────────────────────────────
# Verify Gravitino deployment on EKS
# Run after deploying either broken-s3-token/ or fixed-aws-irsa/ manifests.
# ─────────────────────────────────────────────────────────────────────────────

NS="gravitino-repro"
DEPLOY="gravitino-iceberg-rest"

echo "=== 1. Pod status ==="
kubectl get pods -n "$NS" -l app="$DEPLOY"
echo ""

POD=$(kubectl get pods -n "$NS" -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  echo "ERROR: No pod found. Check deployment."
  exit 1
fi
echo "Pod: $POD"
echo ""

echo "=== 2. IRSA environment check ==="
echo "Looking for AWS_WEB_IDENTITY_TOKEN_FILE and AWS_ROLE_ARN..."
kubectl exec "$POD" -n "$NS" -- env | grep -E "AWS_WEB_IDENTITY|AWS_ROLE_ARN" || echo "  NOT FOUND — IRSA is not configured on this pod"
echo ""

echo "=== 3. Gravitino S3 env vars ==="
echo "Checking if GRAVITINO_S3_ACCESS_KEY is set (it should NOT be for aws-irsa)..."
kubectl exec "$POD" -n "$NS" -- env | grep -E "GRAVITINO_S3_ACCESS|GRAVITINO_S3_SECRET|GRAVITINO_CREDENTIAL" || echo "  No GRAVITINO_S3_ACCESS/SECRET keys found (good for aws-irsa)"
echo ""

echo "=== 4. Rendered config (credential lines) ==="
kubectl exec "$POD" -n "$NS" -- grep -E "s3-access-key|s3-secret-access|credential-providers|s3-role-arn" \
  /root/gravitino-iceberg-rest-server/conf/gravitino-iceberg-rest-server.conf 2>/dev/null || echo "  No credential properties found"
echo ""

echo "=== 5. STS caller identity (from inside pod) ==="
kubectl exec "$POD" -n "$NS" -- aws sts get-caller-identity 2>/dev/null || echo "  aws CLI not available in container (expected — Gravitino image doesn't ship aws CLI)"
echo ""

echo "=== 6. Test Gravitino REST API ==="
# Port-forward temporarily
kubectl port-forward "$POD" 19001:9001 -n "$NS" &
PF_PID=$!
sleep 3

echo "Listing namespaces..."
curl -s http://localhost:19001/iceberg/v1/namespaces 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  Failed to reach Gravitino"
echo ""

echo "Testing credential vending (X-Iceberg-Access-Delegation)..."
# Create a test namespace + table first
curl -sf -X POST http://localhost:19001/iceberg/v1/namespaces \
  -H "Content-Type: application/json" \
  -d '{"namespace": ["irsa_test"], "properties": {}}' >/dev/null 2>&1 || true

curl -sf -X POST http://localhost:19001/iceberg/v1/namespaces/irsa_test/tables \
  -H "Content-Type: application/json" \
  -d '{
    "name": "verify_table",
    "schema": {"type":"struct","schema-id":0,"fields":[{"id":1,"name":"id","type":"long","required":true}]}
  }' >/dev/null 2>&1 || true

RESP=$(curl -s -w "\n%{http_code}" \
  -H "X-Iceberg-Access-Delegation: vended-credentials" \
  http://localhost:19001/iceberg/v1/namespaces/irsa_test/tables/verify_table 2>/dev/null)
CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

if [ "$CODE" = "200" ]; then
  echo "  ✅ SUCCESS (HTTP $CODE) — credential vending works!"
  echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
cfg = d.get('config', {})
if cfg:
    print('  Vended config keys:', list(cfg.keys()))
else:
    print('  (no vended config returned)')
" 2>/dev/null
else
  echo "  ❌ FAILED (HTTP $CODE)"
  echo "$BODY" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('  Error:', d.get('error',{}).get('message','unknown')[:200])
except: print('  Non-JSON response')
" 2>/dev/null
fi

kill $PF_PID 2>/dev/null
echo ""
echo "=== Done ==="
