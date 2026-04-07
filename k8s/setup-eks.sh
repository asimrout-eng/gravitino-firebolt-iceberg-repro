#!/usr/bin/env bash
set -e

# ─────────────────────────────────────────────────────────────────────────────
# Full EKS + Firebolt Cloud End-to-End Setup
# ─────────────────────────────────────────────────────────────────────────────
#
# This script sets up EVERYTHING needed to test:
#   Firebolt Cloud → OAuth → Gravitino (aws-irsa) → Hive Metastore → S3
#
# Prerequisites:
#   - AWS CLI configured with sufficient permissions
#   - eksctl installed (https://eksctl.io)
#   - kubectl installed
#   - AWS Load Balancer Controller addon (for NLB — installed automatically below)
#   - A Firebolt Cloud account
#
# Usage:
#   1. Edit the variables below
#   2. Run: bash k8s/setup-eks.sh
#   3. Follow the Firebolt SQL instructions printed at the end
# ─────────────────────────────────────────────────────────────────────────────

# ── EDIT THESE ───────────────────────────────────────────────────────────────
CLUSTER_NAME="gravitino-repro"
REGION="us-east-1"
S3_BUCKET="asimloadunload"
S3_PREFIX="load/iceberg"
IAM_ROLE_NAME="gravitino-repro-s3-role"
NAMESPACE="gravitino-repro"
SERVICE_ACCOUNT="gravitino-sa"
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Gravitino + Firebolt E2E — EKS Setup                         ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Cluster:     $CLUSTER_NAME"
echo "  Region:      $REGION"
echo "  Account:     $ACCOUNT_ID"
echo "  S3 Bucket:   s3://$S3_BUCKET/$S3_PREFIX"
echo "  IAM Role:    $IAM_ROLE_NAME"
echo ""

# ── Step 1: Create EKS cluster ──────────────────────────────────────────────
echo "━━━ Step 1/8: EKS Cluster ━━━"
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "  Cluster $CLUSTER_NAME already exists, skipping creation"
else
  echo "  Creating EKS cluster (takes ~15 minutes)..."
  eksctl create cluster \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --nodes 2 \
    --node-type t3.medium \
    --with-oidc
fi
echo ""

# ── Step 2: OIDC provider ───────────────────────────────────────────────────
echo "━━━ Step 2/8: OIDC Provider ━━━"
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --approve 2>/dev/null || true

OIDC_URL=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.identity.oidc.issuer" --output text)
OIDC_ID=$(echo "$OIDC_URL" | awk -F'/' '{print $NF}')
echo "  OIDC ID: $OIDC_ID"
echo ""

# ── Step 3: IAM Role for IRSA ───────────────────────────────────────────────
echo "━━━ Step 3/8: IAM Role (IRSA) ━━━"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

cat > /tmp/trust-policy.json <<TRUST
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}",
          "oidc.eks.${REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
TRUST

if aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
  echo "  Role exists, updating trust policy..."
  aws iam update-assume-role-policy --role-name "$IAM_ROLE_NAME" \
    --policy-document file:///tmp/trust-policy.json
else
  echo "  Creating IAM role..."
  aws iam create-role --role-name "$IAM_ROLE_NAME" \
    --assume-role-policy-document file:///tmp/trust-policy.json >/dev/null
fi

cat > /tmp/s3-policy.json <<S3POL
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${S3_BUCKET}/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::${S3_BUCKET}"
    },
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "${ROLE_ARN}"
    }
  ]
}
S3POL

aws iam put-role-policy --role-name "$IAM_ROLE_NAME" \
  --policy-name s3-access \
  --policy-document file:///tmp/s3-policy.json
echo "  Role ARN: $ROLE_ARN"
echo ""

# ── Step 4: Namespace + ServiceAccount ───────────────────────────────────────
echo "━━━ Step 4/8: Namespace + ServiceAccount ━━━"
kubectl apply -f "$SCRIPT_DIR/00-namespace.yaml"

cat <<SA | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICE_ACCOUNT
  namespace: $NAMESPACE
  annotations:
    eks.amazonaws.com/role-arn: "$ROLE_ARN"
SA
echo ""

# ── Step 5: Hive Metastore ──────────────────────────────────────────────────
echo "━━━ Step 5/8: Hive Metastore ━━━"

# Template the hive-site.xml with actual bucket/prefix values
sed "s|__S3_BUCKET__|${S3_BUCKET}|g; s|__S3_PREFIX__|${S3_PREFIX}|g" \
  "$SCRIPT_DIR/04-hive-metastore.yaml" | kubectl apply -f -

echo "  Waiting for Hive Metastore to start (can take 60-90s)..."
kubectl wait --for=condition=ready pod -l app=hive-metastore \
  -n "$NAMESPACE" --timeout=180s 2>/dev/null || echo "  (still starting, will continue...)"
echo ""

# ── Step 6: Gravitino (fixed aws-irsa) ──────────────────────────────────────
echo "━━━ Step 6/8: Gravitino + OAuth ━━━"

# Gravitino ConfigMap with actual values
cat <<CM | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: gravitino-config
  namespace: $NAMESPACE
data:
  GRAVITINO_URI: "thrift://hive-metastore:9083"
  GRAVITINO_WAREHOUSE: "s3://$S3_BUCKET/$S3_PREFIX"
  GRAVITINO_CATALOG_BACKEND: "hive"
  GRAVITINO_IO_IMPL: "org.apache.iceberg.aws.s3.S3FileIO"
  GRAVITINO_S3_REGION: "$REGION"
  GRAVITINO_S3_ENDPOINT: "https://s3.$REGION.amazonaws.com"
  GRAVITINO_S3_PATH_STYLE_ACCESS: "false"
  GRAVITINO_CREDENTIAL_PROVIDERS: "aws-irsa"
  GRAVITINO_S3_ROLE_ARN: "$ROLE_ARN"
CM

kubectl apply -f "$SCRIPT_DIR/fixed-aws-irsa/deployment.yaml"
kubectl apply -f "$SCRIPT_DIR/02-oauth-server.yaml"

echo "  Waiting for Gravitino to start..."
kubectl wait --for=condition=ready pod -l app=gravitino-iceberg-rest \
  -n "$NAMESPACE" --timeout=120s 2>/dev/null || echo "  (still starting...)"
kubectl wait --for=condition=ready pod -l app=oauth-server \
  -n "$NAMESPACE" --timeout=60s 2>/dev/null || echo "  (OAuth starting...)"
echo ""

# ── Step 7: Public NLBs ─────────────────────────────────────────────────────
echo "━━━ Step 7/8: Public NLBs ━━━"
kubectl apply -f "$SCRIPT_DIR/03-public-nlb.yaml"

echo "  Waiting for NLBs to get external hostnames (2-3 minutes)..."
GRAV_DNS=""
OAUTH_DNS=""
for i in $(seq 1 30); do
  if [ -z "$GRAV_DNS" ]; then
    GRAV_DNS=$(kubectl get svc gravitino-public -n "$NAMESPACE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  fi
  if [ -z "$OAUTH_DNS" ]; then
    OAUTH_DNS=$(kubectl get svc oauth-public -n "$NAMESPACE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  fi
  if [ -n "$GRAV_DNS" ] && [ -n "$OAUTH_DNS" ]; then break; fi
  sleep 10
  printf "\r  Waiting... %ds" "$((i * 10))"
done
echo ""
echo ""

# ── Step 8: Create test data ────────────────────────────────────────────────
echo "━━━ Step 8/8: Test Data ━━━"
if [ -n "$GRAV_DNS" ]; then
  bash "$SCRIPT_DIR/create-test-data.sh" "http://${GRAV_DNS}:9001" 2>/dev/null || \
    echo "  (Will retry via port-forward if NLB isn't ready yet)"
  if [ $? -ne 0 ]; then
    echo "  NLB not reachable yet, trying via port-forward..."
    bash "$SCRIPT_DIR/create-test-data.sh"
  fi
else
  echo "  NLB not ready, using port-forward..."
  bash "$SCRIPT_DIR/create-test-data.sh"
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Setup Complete                                                ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Gravitino NLB: ${GRAV_DNS:-<pending — check: kubectl get svc gravitino-public -n $NAMESPACE>}"
echo "  OAuth NLB:     ${OAUTH_DNS:-<pending — check: kubectl get svc oauth-public -n $NAMESPACE>}"
echo ""

if [ -n "$GRAV_DNS" ] && [ -n "$OAUTH_DNS" ]; then
  echo "  ─── Run this in Firebolt Cloud SQL Editor ───"
  echo ""
  echo "  -- Step 1: Create the external location"
  echo "  CREATE LOCATION gravitino_eks_test"
  echo "  WITH"
  echo "    SOURCE = ICEBERG"
  echo "    CATALOG = REST"
  echo "    CATALOG_OPTIONS = ("
  echo "      URL = 'http://${GRAV_DNS}:9001/iceberg/'"
  echo "      WAREHOUSE = 'hive'"
  echo "      OAUTH_SERVER_URI = 'http://${OAUTH_DNS}:8080'"
  echo "      OAUTH_TOKEN_PATH = '/oauth/tokens'"
  echo "      CREDENTIAL = 'firebolt:repro-secret-change-me'"
  echo "    );"
  echo ""
  echo "  -- Step 2: Query the test table (0 rows = success!)"
  echo "  SELECT * FROM READ_ICEBERG("
  echo "    LOCATION => 'gravitino_eks_test',"
  echo "    NAMESPACE => 'repro_test',"
  echo "    TABLE => 'sample_table'"
  echo "  ) LIMIT 10;"
  echo ""
else
  echo "  NLBs are still provisioning. Get the DNS names with:"
  echo "    kubectl get svc -n $NAMESPACE"
  echo ""
  echo "  Then construct the Firebolt SQL:"
  echo "    URL = 'http://<GRAVITINO_NLB>:9001/iceberg/'"
  echo "    OAUTH_SERVER_URI = 'http://<OAUTH_NLB>:8080'"
  echo "    CREDENTIAL = 'firebolt:repro-secret-change-me'"
  echo ""
fi

echo "  ─── Useful commands ───"
echo ""
echo "  Verify IRSA:   bash $SCRIPT_DIR/verify-eks.sh"
echo "  Create data:   bash $SCRIPT_DIR/create-test-data.sh"
echo "  Pod logs:      kubectl logs -l app=gravitino-iceberg-rest -n $NAMESPACE"
echo "  HMS logs:      kubectl logs -l app=hive-metastore -n $NAMESPACE"
echo "  OAuth logs:    kubectl logs -l app=oauth-server -n $NAMESPACE"
echo "  Cleanup:       eksctl delete cluster --name $CLUSTER_NAME --region $REGION"
echo ""
