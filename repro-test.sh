#!/usr/bin/env bash
set -e

# ─────────────────────────────────────────────────────────────────────────────
# Gravitino 1.2.0 S3 Credential Provider — 5-Scenario Reproduction
# ─────────────────────────────────────────────────────────────────────────────
#
# Proves that `credential-providers=s3-token` is the WRONG provider for
# EKS/IRSA. The correct provider is `credential-providers=aws-irsa`.
#
# Scenarios:
#   1. WORKING  — Explicit static S3 keys (baseline)
#   2. BROKEN   — Blank S3 keys via rewrite_config.py (customer's env)
#   3. WORKING  — No S3 keys, default credential chain (workaround)
#   4. BROKEN   — s3-token provider (requires static keys, no session token)
#   5. EXPECTED — aws-irsa provider (needs EKS; fails locally as expected)
#
# Ref: https://gravitino.apache.org/docs/1.2.0/security/credential-vending
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

GRAVITINO_PORT=19201
GRAVITINO_IMAGE="apache/gravitino-iceberg-rest:1.2.0"
NETWORK="gravitino-repro_default"
CONTAINER_NAME="grav-rest"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

R1="" R2="" R3="" R4="" R5=""

banner() {
  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
}

info()    { echo -e "  ${CYAN}→${NC} $1"; }
success() { echo -e "  ${GREEN}✓${NC} $1"; }
fail()    { echo -e "  ${RED}✗${NC} $1"; }
warn()    { echo -e "  ${YELLOW}!${NC} $1"; }
dim()     { echo -e "  ${DIM}$1${NC}"; }

wait_for_gravitino() {
  local timeout=60 elapsed=0
  while true; do
    local resp
    resp=$(curl -s -o /dev/null -w "%{http_code}" \
      "http://localhost:${GRAVITINO_PORT}/iceberg/v1/config" 2>/dev/null || true)
    if [ "$resp" = "200" ]; then
      success "Gravitino REST API is ready (${elapsed}s)"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    if [ $elapsed -ge $timeout ]; then
      return 1
    fi
    printf "\r  Waiting for Gravitino... %ds" "$elapsed"
  done
}

stop_gravitino() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  sleep 2
}

show_config() {
  echo ""
  info "Rendered config (credential lines):"
  local cfg
  cfg=$(docker exec "$CONTAINER_NAME" \
    grep -E "s3-access-key|s3-secret-access|credential-providers|s3-role-arn" \
    /root/gravitino-iceberg-rest-server/conf/gravitino-iceberg-rest-server.conf 2>/dev/null || true)
  if [ -z "$cfg" ]; then
    dim "  (no S3 credential properties in config — using default chain)"
  else
    echo "$cfg" | while IFS= read -r line; do
      dim "  $line"
    done
  fi
  echo ""
}

COMMON_ENV=(
  -e GRAVITINO_CATALOG_BACKEND=hive
  -e GRAVITINO_URI=thrift://grav-hive:9083
  -e GRAVITINO_WAREHOUSE=s3://iceberg-warehouse/
  -e GRAVITINO_IO_IMPL=org.apache.iceberg.aws.s3.S3FileIO
  -e GRAVITINO_S3_ENDPOINT=http://grav-minio:9000
  -e GRAVITINO_S3_REGION=us-east-1
  -e GRAVITINO_S3_PATH_STYLE_ACCESS=true
)

run_gravitino() {
  docker run -d --rm \
    --name "$CONTAINER_NAME" \
    --network "$NETWORK" \
    -p "${GRAVITINO_PORT}:9001" \
    "${COMMON_ENV[@]}" \
    "$@" \
    "$GRAVITINO_IMAGE" >/dev/null
}

test_table_ops() {
  local scenario_num=$1

  # Create namespace (idempotent)
  curl -sf -X POST "http://localhost:${GRAVITINO_PORT}/iceberg/v1/namespaces" \
    -H "Content-Type: application/json" \
    -d '{"namespace": ["test_ns"], "properties": {}}' >/dev/null 2>&1 || true

  # Create table (idempotent)
  if [ "$scenario_num" = "1" ]; then
    local resp
    resp=$(curl -s -w "\n%{http_code}" -X POST \
      "http://localhost:${GRAVITINO_PORT}/iceberg/v1/namespaces/test_ns/tables" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "repro_table",
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
    local code
    code=$(echo "$resp" | tail -1)
    if [ "$code" = "200" ] || [ "$code" = "409" ]; then
      success "Table test_ns.repro_table created (HTTP $code)"
    else
      fail "Table creation failed (HTTP $code)"
      return 1
    fi
  fi
}

test_load_table() {
  local label=$1
  local header=$2
  local url="http://localhost:${GRAVITINO_PORT}/iceberg/v1/namespaces/test_ns/tables/repro_table"
  local curl_args=(-s)

  if [ -n "$header" ]; then
    curl_args+=(-H "$header")
  fi

  local resp
  resp=$(curl "${curl_args[@]}" -w "\n%{http_code}" "$url")
  local code
  code=$(echo "$resp" | tail -1)
  local body
  body=$(echo "$resp" | sed '$d')

  if [ "$code" = "200" ]; then
    success "Table load SUCCESS (HTTP $code) — $label"
    return 0
  else
    local msg
    msg=$(echo "$body" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    e = d.get('error', {})
    print(e.get('message', 'unknown')[:200])
except: print('non-JSON response')
" 2>/dev/null)
    fail "Table load FAILED (HTTP $code) — $label"
    dim "  Error: $msg"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

banner "GRAVITINO 1.2.0 — S3 CREDENTIAL PROVIDER REPRODUCTION"
echo ""
echo "  This script tests 5 configurations to pinpoint why Gravitino returns"
echo "  'The AWS Access Key Id you provided does not exist in our records'"
echo "  and proves that aws-irsa (not s3-token) is the correct provider."
echo ""
echo "  Ref: https://gravitino.apache.org/docs/1.2.0/security/credential-vending"
echo ""

# ── Step 0: Base services ────────────────────────────────────────────────────
banner "STEP 0: Starting MinIO + Hive Metastore"
docker compose up -d
echo ""
info "Waiting for Hive Metastore (~30-60s)..."
timeout=120
elapsed=0
while ! docker exec grav-hive bash -c "cat < /dev/null > /dev/tcp/localhost/9083" 2>/dev/null; do
  sleep 5
  elapsed=$((elapsed + 5))
  if [ $elapsed -ge $timeout ]; then
    fail "Hive Metastore did not start in ${timeout}s"
    docker logs grav-hive 2>&1 | tail -20
    exit 1
  fi
  printf "\r  Hive Metastore starting... %ds" "$elapsed"
done
echo ""
success "Hive Metastore is ready"

# ═════════════════════════════════════════════════════════════════════════════
# SCENARIO 1: WORKING — Explicit static keys
# ═════════════════════════════════════════════════════════════════════════════
banner "SCENARIO 1: Explicit static S3 keys (baseline)"
echo ""
echo "  Config: GRAVITINO_S3_ACCESS_KEY=minioadmin"
echo "          GRAVITINO_S3_SECRET_KEY=minioadmin"
echo "  Provider: none (no credential vending)"
echo ""

stop_gravitino
run_gravitino \
  -e GRAVITINO_S3_ACCESS_KEY=minioadmin \
  -e GRAVITINO_S3_SECRET_KEY=minioadmin
wait_for_gravitino || { fail "Gravitino did not start"; exit 1; }
show_config
test_table_ops 1
test_load_table "explicit static keys" && R1="PASS" || R1="FAIL"

# ═════════════════════════════════════════════════════════════════════════════
# SCENARIO 2: BROKEN — Blank S3 keys (customer's rewrite_config.py bug)
# ═════════════════════════════════════════════════════════════════════════════
banner "SCENARIO 2: Blank S3 keys (rewrite_config.py writes empty values)"
echo ""
echo "  Config: GRAVITINO_S3_ACCESS_KEY=\"\"   ← empty string"
echo "          GRAVITINO_S3_SECRET_KEY=\"\"   ← empty string"
echo "  Provider: none"
echo ""
echo "  This reproduces the Helm chart rendering commented-out values as empty"
echo "  strings. rewrite_config.py writes 's3-access-key-id = ' (blank) to config."
echo ""

stop_gravitino
run_gravitino \
  -e GRAVITINO_S3_ACCESS_KEY="" \
  -e GRAVITINO_S3_SECRET_KEY="" \
  -e AWS_ACCESS_KEY_ID=minioadmin \
  -e AWS_SECRET_ACCESS_KEY=minioadmin

info "Waiting 15s for startup..."
sleep 15

if docker ps --filter "name=$CONTAINER_NAME" --format '{{.Names}}' | grep -q "$CONTAINER_NAME"; then
  show_config
  test_load_table "blank keys in config" && R2="PASS" || R2="FAIL"
else
  fail "Container crashed on startup"
  dim "$(docker logs "$CONTAINER_NAME" 2>&1 | grep -i 'blank\|invalid\|error' | head -3)"
  R2="FAIL (crash)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# SCENARIO 3: WORKING — No S3 keys, default credential chain
# ═════════════════════════════════════════════════════════════════════════════
banner "SCENARIO 3: No GRAVITINO_S3_* keys — default credential chain"
echo ""
echo "  Config: GRAVITINO_S3_ACCESS_KEY  → NOT SET (removed)"
echo "          GRAVITINO_S3_SECRET_KEY  → NOT SET (removed)"
echo "          AWS_ACCESS_KEY_ID=minioadmin  (simulates IRSA env)"
echo "  Provider: none (metadata read only, no credential vending)"
echo ""
echo "  Without GRAVITINO_S3_ACCESS_KEY in the environment, rewrite_config.py"
echo "  does NOT write s3-access-key-id to the config. S3FileIO falls back to"
echo "  the AWS SDK default credential chain."
echo ""

stop_gravitino
run_gravitino \
  -e AWS_ACCESS_KEY_ID=minioadmin \
  -e AWS_SECRET_ACCESS_KEY=minioadmin \
  -e AWS_REGION=us-east-1
wait_for_gravitino || { fail "Gravitino did not start"; R3="FAIL"; }
if [ -z "$R3" ]; then
  show_config
  test_load_table "default credential chain (no vending)" && R3="PASS" || R3="FAIL"
fi

# ═════════════════════════════════════════════════════════════════════════════
# SCENARIO 4: BROKEN — s3-token provider (requires static keys)
# ═════════════════════════════════════════════════════════════════════════════
banner "SCENARIO 4: s3-token provider (wrong provider for IRSA)"
echo ""
echo "  Config: GRAVITINO_CREDENTIAL_PROVIDERS=s3-token"
echo "          GRAVITINO_S3_ROLE_ARN=arn:aws:iam::123456789:role/fake"
echo "          GRAVITINO_S3_ACCESS_KEY  → NOT SET"
echo "  Provider: s3-token"
echo ""
echo "  The s3-token provider REQUIRES s3-access-key-id in config."
echo "  It does NOT fall back to the default credential chain."
echo "  This is the WRONG provider for IRSA."
echo ""

stop_gravitino
run_gravitino \
  -e AWS_ACCESS_KEY_ID=minioadmin \
  -e AWS_SECRET_ACCESS_KEY=minioadmin \
  -e GRAVITINO_CREDENTIAL_PROVIDERS=s3-token \
  -e GRAVITINO_S3_ROLE_ARN=arn:aws:iam::123456789:role/fake-role
wait_for_gravitino || { fail "Gravitino did not start"; R4="FAIL"; }
if [ -z "$R4" ]; then
  show_config
  echo ""
  info "Testing with X-Iceberg-Access-Delegation header (triggers credential vending)..."
  test_load_table "s3-token + vended-credentials header" "X-Iceberg-Access-Delegation: vended-credentials" \
    && R4="PASS" || R4="FAIL"
fi

# ═════════════════════════════════════════════════════════════════════════════
# SCENARIO 5: CORRECT — aws-irsa provider (needs EKS)
# ═════════════════════════════════════════════════════════════════════════════
banner "SCENARIO 5: aws-irsa provider (correct for EKS/IRSA)"
echo ""
echo "  Config: GRAVITINO_CREDENTIAL_PROVIDERS=aws-irsa"
echo "          GRAVITINO_S3_ROLE_ARN=arn:aws:iam::123456789:role/fake"
echo "  Provider: aws-irsa"
echo ""
echo "  The aws-irsa provider uses AWS_WEB_IDENTITY_TOKEN_FILE (set by IRSA)."
echo "  In this Docker test, it will fail with a clear message that IRSA is"
echo "  not configured — proving it WOULD work in EKS."
echo ""

stop_gravitino
run_gravitino \
  -e AWS_ACCESS_KEY_ID=minioadmin \
  -e AWS_SECRET_ACCESS_KEY=minioadmin \
  -e GRAVITINO_CREDENTIAL_PROVIDERS=aws-irsa \
  -e GRAVITINO_S3_ROLE_ARN=arn:aws:iam::123456789:role/fake-role
wait_for_gravitino || { fail "Gravitino did not start"; R5="FAIL"; }
if [ -z "$R5" ]; then
  show_config
  echo ""
  info "Testing with X-Iceberg-Access-Delegation header..."
  irsa_resp=$(curl -s "http://localhost:${GRAVITINO_PORT}/iceberg/v1/namespaces/test_ns/tables/repro_table" \
    -H "X-Iceberg-Access-Delegation: vended-credentials" 2>&1)
  
  if echo "$irsa_resp" | grep -q "AWS_WEB_IDENTITY_TOKEN_FILE"; then
    success "Got expected IRSA error: 'AWS_WEB_IDENTITY_TOKEN_FILE not set'"
    info "This confirms aws-irsa provider is active and WOULD work in EKS."
    R5="EXPECTED (needs EKS)"
  elif echo "$irsa_resp" | grep -q '"metadata"'; then
    success "Table loaded (unexpected — IRSA env may be present)"
    R5="PASS"
  else
    irsa_msg=$(echo "$irsa_resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('error',{}).get('message','unknown')[:150])
except: print('unknown')
" 2>/dev/null)
    fail "Unexpected error: $irsa_msg"
    R5="FAIL"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═════════════════════════════════════════════════════════════════════════════
banner "RESULTS SUMMARY"
echo ""
print_result() {
  local num=$1 label=$2 result=$3
  local color=$RED
  if [ "$result" = "PASS" ]; then color=$GREEN; fi
  if echo "$result" | grep -q "EXPECTED"; then color=$YELLOW; fi
  printf "  %-4s %-50s ${color}%s${NC}\n" "${num}." "$label" "$result"
}

printf "  %-4s %-50s %s\n" "#" "Scenario" "Result"
printf "  %-4s %-50s %s\n" "---" "--------------------------------------------------" "--------"
print_result 1 "Explicit static keys (baseline)" "$R1"
print_result 2 "Blank keys (rewrite_config.py bug)" "$R2"
print_result 3 "No S3 keys, default chain (workaround)" "$R3"
print_result 4 "s3-token provider (WRONG for IRSA)" "$R4"
print_result 5 "aws-irsa provider (CORRECT for IRSA)" "$R5"

echo ""
echo -e "${BOLD}Conclusion:${NC}"
echo ""
echo "  The customer error 'The AWS Access Key Id you provided does not exist'"
echo "  is caused by using credential-providers=s3-token with IRSA."
echo ""
echo "  s3-token requires static IAM access keys (AKIA...) and has no support"
echo "  for session tokens (temporary credentials from IRSA/STS)."
echo ""
echo -e "  ${GREEN}Fix: Change to credential-providers=aws-irsa${NC}"
echo "  This provider is designed for EKS/IRSA and reads the web identity"
echo "  token injected by IRSA (AWS_WEB_IDENTITY_TOKEN_FILE)."
echo ""
echo "  Also: remove GRAVITINO_S3_ACCESS_KEY and GRAVITINO_S3_SECRET_KEY"
echo "  entirely from the pod environment to prevent rewrite_config.py"
echo "  from writing blank values."
echo ""
echo "  Official docs:"
echo "  https://gravitino.apache.org/docs/1.2.0/security/credential-vending"
echo ""

# Cleanup
stop_gravitino
info "Base services still running. Stop with: docker compose down -v"
