#!/usr/bin/env bash
set -e

# ─────────────────────────────────────────────────────────────────────────────
# Full EKS + Firebolt Cloud End-to-End Setup
# ─────────────────────────────────────────────────────────────────────────────
#
# This script sets up everything needed to test Firebolt Cloud → Gravitino
# with aws-irsa credential vending on EKS.
#
# Prerequisites:
#   - AWS CLI configured with sufficient permissions
#   - eksctl installed (https://eksctl.io)
#   - kubectl installed
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
HIVE_METASTORE_URI="thrift://hive-metastore:9083"  # Change if using external HMS
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "=== Settings ==="
echo "  Cluster:     $CLUSTER_NAME"
echo "  Region:      $REGION"
echo "  Account:     $ACCOUNT_ID"
echo "  S3 Bucket:   s3://$S3_BUCKET/$S3_PREFIX"
echo "  IAM Role:    $IAM_ROLE_NAME"
echo ""

# ── Step 1: Create EKS cluster (skip if exists) ─────────────────────────────
echo "=== Step 1: EKS Cluster ==="
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  echo "  Cluster $CLUSTER_NAME already exists, skipping creation"
else
  echo "  Creating EKS cluster (this takes ~15 minutes)..."
  eksctl create cluster \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --nodes 2 \
    --node-type t3.medium \
    --with-oidc
fi
echo ""

# ── Step 2: OIDC provider ───────────────────────────────────────────────────
echo "=== Step 2: OIDC Provider ==="
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
echo "=== Step 3: IAM Role ==="
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
  echo "  Role $IAM_ROLE_NAME exists, updating trust policy..."
  aws iam update-assume-role-policy --role-name "$IAM_ROLE_NAME" \
    --policy-document file:///tmp/trust-policy.json
else
  echo "  Creating IAM role $IAM_ROLE_NAME..."
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
    }
  ]
}
S3POL

aws iam put-role-policy --role-name "$IAM_ROLE_NAME" \
  --policy-name s3-access \
  --policy-document file:///tmp/s3-policy.json
echo "  Role ARN: $ROLE_ARN"
echo ""

# ── Step 4: Deploy K8s manifests ────────────────────────────────────────────
echo "=== Step 4: Deploy to EKS ==="

kubectl apply -f "$SCRIPT_DIR/00-namespace.yaml"

# Create ServiceAccount with IRSA annotation
cat <<SA | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SERVICE_ACCOUNT
  namespace: $NAMESPACE
  annotations:
    eks.amazonaws.com/role-arn: "$ROLE_ARN"
SA

# Update ConfigMap with actual values
cat <<CM | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: gravitino-config
  namespace: $NAMESPACE
data:
  GRAVITINO_URI: "$HIVE_METASTORE_URI"
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
kubectl apply -f "$SCRIPT_DIR/03-public-nlb.yaml"

echo ""
echo "  Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app=gravitino-iceberg-rest \
  -n "$NAMESPACE" --timeout=120s 2>/dev/null || echo "  (still starting...)"
echo ""

# ── Step 5: Get NLB endpoint ────────────────────────────────────────────────
echo "=== Step 5: Firebolt Cloud Connection ==="
echo ""
echo "  Waiting for NLB to get external IP (may take 2-3 minutes)..."

NLB_DNS=""
for i in $(seq 1 30); do
  NLB_DNS=$(kubectl get svc gravitino-public -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [ -n "$NLB_DNS" ]; then break; fi
  sleep 10
  printf "\r  Waiting... %ds" "$((i * 10))"
done
echo ""

if [ -z "$NLB_DNS" ]; then
  echo "  NLB not ready yet. Check with:"
  echo "    kubectl get svc gravitino-public -n $NAMESPACE"
  echo ""
else
  echo "  NLB DNS: $NLB_DNS"
  echo ""
  echo "  ─── Run these in Firebolt Cloud ───"
  echo ""
  echo "  CREATE LOCATION gravitino_eks_test"
  echo "  WITH"
  echo "    SOURCE = ICEBERG"
  echo "    CATALOG = REST"
  echo "    CATALOG_OPTIONS = ("
  echo "      URL = 'http://${NLB_DNS}:9001/iceberg/'"
  echo "      WAREHOUSE = 'hive'"
  echo "      OAUTH_SERVER_URI = 'http://${NLB_DNS}:8080'"
  echo "      OAUTH_TOKEN_PATH = '/oauth/tokens'"
  echo "      CREDENTIAL = 'firebolt:repro-secret-change-me'"
  echo "    );"
  echo ""
  echo "  SELECT * FROM READ_ICEBERG("
  echo "    LOCATION => 'gravitino_eks_test',"
  echo "    NAMESPACE => '<your_namespace>',"
  echo "    TABLE => '<your_table>'"
  echo "  ) LIMIT 10;"
  echo ""
fi

echo "=== Done ==="
echo ""
echo "  Verify IRSA:  kubectl exec <pod> -n $NAMESPACE -- env | grep AWS_WEB_IDENTITY"
echo "  Verify:       bash $SCRIPT_DIR/verify-eks.sh"
echo "  Cleanup:      eksctl delete cluster --name $CLUSTER_NAME --region $REGION"
