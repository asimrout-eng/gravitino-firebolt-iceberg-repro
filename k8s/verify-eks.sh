#!/usr/bin/env bash
set -e

# Verify the full Gravitino + HMS + OAuth deployment on EKS.
# Run after setup-eks.sh or manual deployment.

NS="gravitino-repro"
PF_PIDS=""
cleanup() { for p in $PF_PIDS; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  EKS Deployment Verification                                   ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Pod status ────────────────────────────────────────────────────────────
echo "━━━ 1. Pod Status ━━━"
kubectl get pods -n "$NS" -o wide
echo ""

# ── 2. IRSA check on Gravitino pod ──────────────────────────────────────────
echo "━━━ 2. IRSA Environment (Gravitino pod) ━━━"
POD=$(kubectl get pods -n "$NS" -l app=gravitino-iceberg-rest -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  echo "  ERROR: No Gravitino pod found"
else
  echo "  Pod: $POD"
  kubectl exec "$POD" -n "$NS" -- env 2>/dev/null | grep -E "AWS_WEB_IDENTITY|AWS_ROLE_ARN" \
    || echo "  NOT FOUND — IRSA is not configured (check ServiceAccount annotation)"
fi
echo ""

# ── 3. IRSA check on HMS pod ────────────────────────────────────────────────
echo "━━━ 3. IRSA Environment (Hive Metastore pod) ━━━"
HMS_POD=$(kubectl get pods -n "$NS" -l app=hive-metastore -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$HMS_POD" ]; then
  echo "  No Hive Metastore pod found (may be using external HMS)"
else
  echo "  Pod: $HMS_POD"
  kubectl exec "$HMS_POD" -n "$NS" -- env 2>/dev/null | grep -E "AWS_WEB_IDENTITY|AWS_ROLE_ARN" \
    || echo "  NOT FOUND — IRSA is not configured"
fi
echo ""

# ── 4. Gravitino env vars ───────────────────────────────────────────────────
echo "━━━ 4. Gravitino Credential Config ━━━"
if [ -n "$POD" ]; then
  echo "  Checking GRAVITINO_S3_ACCESS_KEY (should NOT be set for aws-irsa):"
  HAS_KEY=$(kubectl exec "$POD" -n "$NS" -- env 2>/dev/null | grep "GRAVITINO_S3_ACCESS_KEY" || true)
  if [ -n "$HAS_KEY" ]; then
    echo "  WARNING: GRAVITINO_S3_ACCESS_KEY is set — this overrides IRSA!"
    echo "  $HAS_KEY"
  else
    echo "  OK — no static S3 keys in environment"
  fi
  echo ""
  echo "  Credential provider config:"
  kubectl exec "$POD" -n "$NS" -- env 2>/dev/null | grep "GRAVITINO_CREDENTIAL" || echo "  (not set via env)"
fi
echo ""

# ── 5. Rendered config file ─────────────────────────────────────────────────
echo "━━━ 5. Rendered Config (credential lines) ━━━"
if [ -n "$POD" ]; then
  kubectl exec "$POD" -n "$NS" -- grep -E "s3-access-key|s3-secret-access|credential-providers|s3-role-arn" \
    /root/gravitino-iceberg-rest-server/conf/gravitino-iceberg-rest-server.conf 2>/dev/null \
    || echo "  No credential properties found in config file"
fi
echo ""

# ── 6. OAuth server health ──────────────────────────────────────────────────
echo "━━━ 6. OAuth Server Health ━━━"
OAUTH_POD=$(kubectl get pods -n "$NS" -l app=oauth-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$OAUTH_POD" ]; then
  echo "  No OAuth pod found"
else
  echo "  Pod: $OAUTH_POD"
  kubectl port-forward "$OAUTH_POD" 18080:8080 -n "$NS" &
  PF_PIDS="$PF_PIDS $!"
  sleep 2
  HEALTH=$(curl -s http://localhost:18080/health 2>/dev/null || echo "unreachable")
  echo "  /health: $HEALTH"
fi
echo ""

# ── 7. Gravitino REST API test ───────────────────────────────────────────────
echo "━━━ 7. Gravitino REST API Test ━━━"
if [ -n "$POD" ]; then
  kubectl port-forward "$POD" 19001:9001 -n "$NS" &
  PF_PIDS="$PF_PIDS $!"
  sleep 3

  echo "  Listing namespaces..."
  curl -s http://localhost:19001/iceberg/v1/namespaces 2>/dev/null \
    | python3 -m json.tool 2>/dev/null || echo "  Failed to reach Gravitino"
  echo ""

  echo "  Testing credential vending..."
  # Try loading a table with credential vending header
  curl -sf -X POST http://localhost:19001/iceberg/v1/namespaces \
    -H "Content-Type: application/json" \
    -d '{"namespace": ["verify_test"], "properties": {}}' >/dev/null 2>&1 || true

  curl -sf -X POST http://localhost:19001/iceberg/v1/namespaces/verify_test/tables \
    -H "Content-Type: application/json" \
    -d '{
      "name": "check_creds",
      "schema": {"type":"struct","schema-id":0,"fields":[{"id":1,"name":"id","type":"long","required":true}]}
    }' >/dev/null 2>&1 || true

  RESP=$(curl -s -w "\n%{http_code}" \
    -H "X-Iceberg-Access-Delegation: vended-credentials" \
    http://localhost:19001/iceberg/v1/namespaces/verify_test/tables/check_creds 2>/dev/null)
  CODE=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | sed '$d')

  if [ "$CODE" = "200" ]; then
    echo "  SUCCESS (HTTP $CODE) — credential vending works!"
    echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
cfg = d.get('config', {})
if 's3.access-key-id' in cfg:
    print('  Vended S3 key starts with:', cfg['s3.access-key-id'][:8] + '...')
    print('  Vended S3 session token:', 'present' if cfg.get('s3.session-token') else 'missing')
else:
    print('  Config keys:', list(cfg.keys()) if cfg else '(none)')
" 2>/dev/null || true
  else
    echo "  FAILED (HTTP $CODE)"
    echo "$BODY" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('  Error:', d.get('error',{}).get('message','unknown')[:200])
except: print('  Non-JSON response')
" 2>/dev/null || true
  fi

fi
echo ""

# ── 8. NLB status ───────────────────────────────────────────────────────────
echo "━━━ 8. NLB External Endpoints ━━━"
kubectl get svc gravitino-public oauth-public -n "$NS" 2>/dev/null \
  || echo "  NLB services not found — run setup-eks.sh first"
echo ""

echo "━━━ Done ━━━"
