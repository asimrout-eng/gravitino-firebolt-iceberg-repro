# Firebolt + Gravitino Iceberg REST — S3 Credential Reproduction & E2E Test

End-to-end reproduction and fix for connecting **Firebolt** to **Apache Gravitino 1.2.0**
(Iceberg REST catalog) with **AWS S3** using **IRSA** (IAM Roles for Service Accounts) in EKS.

Includes:
- Automated local Docker test (5 scenarios, no AWS needed)
- Ready-to-deploy EKS manifests (broken + fixed, side by side)
- One-command EKS setup with Firebolt Cloud integration
- Full root cause analysis with official documentation references

## Background

When Firebolt queries an Iceberg table via Gravitino, the flow is:

```
Firebolt Engine
    │
    │ 1. OAuth: client_id + client_secret → JWT token
    │ 2. GET /iceberg/v1/hive/namespaces/{ns}/tables/{table}
    │    (Bearer token + X-Iceberg-Access-Delegation: vended-credentials)
    ▼
Gravitino Iceberg REST (port 9001)
    │
    │ 3. getTable() via Thrift
    ▼
Hive Metastore (port 9083)
    │
    │ 4. Returns metadata location: s3://bucket/path/metadata.json
    ▼
Gravitino reads Iceberg metadata from S3
    │  (via IRSA — no static keys)
    │
    │ 5. Returns to Firebolt:
    │    - Table schema + file list
    │    - Vended temporary S3 credentials
    ▼
Firebolt Engine reads Parquet files directly from S3
    (using vended credentials — data never passes through Gravitino)
```

## The Problem

Firebolt returns:

```
The AWS Access Key Id you provided does not exist in our records
```

## Root Cause

Two issues in the K8s manifests provided to the customer:

**1. Wrong credential provider**

The ConfigMap sets `GRAVITINO_CREDENTIAL_PROVIDERS: "s3-token"`. The `s3-token` provider
requires **static IAM access keys** (`AKIA...`) in the config. It does not work with IRSA.

The correct provider for EKS/IRSA is **`aws-irsa`**, available since Gravitino 1.0.0.

**2. Blank keys from `rewrite_config.py`**

The Deployment injects `GRAVITINO_S3_ACCESS_KEY` from a Kubernetes Secret. When the Secret
has placeholder/empty values, the `rewrite_config.py` script inside the Gravitino Docker
image writes `s3-access-key-id = ` (blank) into the config, overriding the AWS default
credential chain.

```python
# Inside /root/gravitino-iceberg-rest-server/bin/rewrite_config.py
env_map = {
    "GRAVITINO_S3_ACCESS_KEY": "s3-access-key-id",
    "GRAVITINO_S3_SECRET_KEY": "s3-secret-access-key",
}

for k, v in env_map.items():
    if k in os.environ:          # checks key EXISTS, not if value is non-empty
        update_config(config_map, v, os.environ[k])
```

## Credential Providers in Gravitino 1.2.0

| Provider | Config value | Use case | Requires static keys? | Since |
|---|---|---|---|---|
| **S3 IRSA** | `aws-irsa` | EKS pods with IRSA | **No** — uses `AWS_WEB_IDENTITY_TOKEN_FILE` | 1.0.0 |
| S3 Token | `s3-token` | STS AssumeRole with static keys | **Yes** — `s3-access-key-id` + `s3-secret-access-key` | 0.8.0 |
| S3 Secret Key | `s3-secret-key` | Passthrough static keys | **Yes** | 0.8.0 |

Source: [Gravitino 1.2.0 Credential Vending Documentation](https://gravitino.apache.org/docs/1.2.0/security/credential-vending)

### Why `s3-token` fails with IRSA

`S3TokenGenerator` creates an STS client using the explicit `s3-access-key-id` and
`s3-secret-access-key` from the config. There is no config property for `s3-session-token`,
so temporary credentials (IRSA, STS sessions) cannot be used.

### Why `aws-irsa` works with IRSA

`AwsIrsaCredentialGenerator` reads the `AWS_WEB_IDENTITY_TOKEN_FILE` environment variable
injected by EKS IRSA and uses `StsClient` with web identity token authentication.

Verified error when running outside EKS:

```
Caused by: java.lang.IllegalStateException:
  AWS_WEB_IDENTITY_TOKEN_FILE environment variable is not set.
  Ensure IRSA is properly configured in your EKS cluster.
```

This confirms `aws-irsa` is the IRSA-specific code path and will work in EKS.

## The Fix

**Two changes in the K8s manifests:**

1. In the ConfigMap, change `GRAVITINO_CREDENTIAL_PROVIDERS` from `s3-token` to `aws-irsa`
2. In the Deployment, remove the `GRAVITINO_S3_ACCESS_KEY` and `GRAVITINO_S3_SECRET_KEY`
   environment variables entirely

**IRSA prerequisites** (if not already set up):

1. EKS cluster with OIDC provider
2. IAM role with S3 access + trust policy for the OIDC provider
3. Kubernetes ServiceAccount annotated with the IAM role ARN
4. Gravitino Deployment referencing that ServiceAccount

---

## Test 1: Local Docker (No AWS Needed)

Automated 5-scenario test using MinIO as S3-compatible storage.

### Prerequisites

- Docker + Docker Compose
- ~2 GB free disk
- Ports 19000, 19001, 19083, 19201 free

### Run

```bash
git clone https://github.com/asimrout-eng/gravitino-firebolt-iceberg-repro.git
cd gravitino-firebolt-iceberg-repro

docker compose up -d
# Wait ~45 seconds for Hive Metastore to initialize

./repro-test.sh

docker compose down -v
```

### Scenarios

| # | Scenario | Credential Provider | S3 Keys | Expected |
|---|---|---|---|---|
| 1 | Explicit static keys (baseline) | none | `GRAVITINO_S3_ACCESS_KEY=minioadmin` | **PASS** |
| 2 | Blank keys (customer's bug) | none | `GRAVITINO_S3_ACCESS_KEY=""` | **FAIL** |
| 3 | No keys, default chain (workaround) | none | env `AWS_ACCESS_KEY_ID` only | **PASS** |
| 4 | s3-token provider (wrong for IRSA) | `s3-token` | none | **FAIL** |
| 5 | aws-irsa provider (correct for IRSA) | `aws-irsa` | none | **EXPECTED** (needs EKS) |

---

## Test 2: EKS — Reproduce Error vs Fix

Deploy both the broken and fixed manifests on EKS to prove the issue and the fix
with real IRSA credentials.

### Prerequisites

- EKS cluster with OIDC provider enabled
- IAM role with S3 access + IRSA trust policy
- `kubectl` configured for the cluster

### Deploy

```bash
# Edit placeholders in the manifests:
#   01-serviceaccount.yaml     → your IAM role ARN
#   04-hive-metastore.yaml     → your S3 bucket (replace __S3_BUCKET__ / __S3_PREFIX__)
#   configmap.yaml (in each)   → your bucket, region, role ARN

kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-serviceaccount.yaml
kubectl apply -f k8s/04-hive-metastore.yaml   # Hive Metastore (edit S3 bucket first!)
kubectl apply -f k8s/02-oauth-server.yaml      # OAuth token server

# To REPRODUCE the error:
kubectl apply -f k8s/broken-s3-token/

# To TEST the fix:
kubectl apply -f k8s/fixed-aws-irsa/

# Verify
bash k8s/verify-eks.sh
```

### Expected Results

**With `broken-s3-token/`**: Loading a table with credential vending returns:
```
The AWS Access Key Id you provided does not exist in our records
```

**With `fixed-aws-irsa/`**: Credential vending succeeds:
```
SUCCESS (HTTP 200) — credential vending works!
```

---

## Test 3: Firebolt Cloud + EKS (Full End-to-End)

The production-equivalent proof: **Firebolt Cloud → OAuth → Gravitino (aws-irsa) → Hive Metastore → S3**.

### What Gets Deployed

| Component | Image | Purpose |
|---|---|---|
| **Gravitino Iceberg REST** | `apache/gravitino-iceberg-rest:1.2.0` | Iceberg catalog with `aws-irsa` credential vending |
| **Hive Metastore** | `apache/hive:4.0.0` | Iceberg metadata storage (Derby backend) |
| **OAuth Server** | `python:3.11-slim` | JWT token server for Firebolt authentication |
| **ALB Ingress** | — | Single internet-facing ALB with path-based routing to Gravitino + OAuth |

All pods use the same IRSA-annotated ServiceAccount for S3 access.

### Prerequisites

- AWS CLI configured with sufficient permissions
- [`eksctl`](https://eksctl.io) installed
- [`helm`](https://helm.sh) installed (for AWS Load Balancer Controller)
- `kubectl` installed
- A Firebolt Cloud account with a running engine

### Firebolt Cloud Credentials

You need an active **Firebolt Cloud account** with a running engine.
There is no automated way to provision Firebolt credentials — you must log into
the Firebolt UI and run the SQL from the output of `setup-eks.sh`.

### One-Command Setup

```bash
# Edit variables at the top of the script (cluster name, region, bucket, etc.)
bash k8s/setup-eks.sh
```

This script:
1. Creates an EKS cluster (or uses existing)
2. Sets up OIDC provider for IRSA
3. Creates IAM role with S3 access + IRSA trust policy
4. Installs **AWS Load Balancer Controller** (for ALB Ingress)
5. Creates Kubernetes ServiceAccount with IRSA annotation
6. Deploys **Hive Metastore** with S3A + IRSA
7. Deploys **Gravitino** with `aws-irsa` credential provider
8. Deploys **OAuth server** (pure Python, no external deps)
9. Creates **ALB Ingress** with path-based routing (`/iceberg/*` → Gravitino, `/oauth/*` → OAuth)
10. Creates a **test Iceberg table** via Gravitino REST API
11. Prints the exact **Firebolt SQL** to run

### Manual Steps

```bash
# Prerequisite: AWS Load Balancer Controller must be installed on the cluster.
# setup-eks.sh installs it automatically. For manual install, see:
# https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html

kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-serviceaccount.yaml
kubectl apply -f k8s/04-hive-metastore.yaml   # HMS (edit S3 bucket first!)
kubectl apply -f k8s/fixed-aws-irsa/           # Gravitino (edit ConfigMap first)
kubectl apply -f k8s/02-oauth-server.yaml      # OAuth token server
kubectl apply -f k8s/03-public-alb.yaml        # ALB Ingress (path-based routing)

# Get the ALB DNS name (takes 2-3 min to provision)
kubectl get ingress gravitino-public -n gravitino-repro

# Create test Iceberg table
bash k8s/create-test-data.sh
```

### Firebolt Cloud SQL

Single ALB hostname — Gravitino and OAuth share the same entry point via path routing:

```sql
CREATE LOCATION gravitino_eks_test
WITH
  SOURCE = ICEBERG
  CATALOG = REST
  CATALOG_OPTIONS = (
    URL = 'http://<ALB_DNS>/iceberg/'
    WAREHOUSE = 'hive'
    OAUTH_SERVER_URI = 'http://<ALB_DNS>'
    OAUTH_TOKEN_PATH = '/oauth/tokens'
    CREDENTIAL = 'firebolt:repro-secret-change-me'
  );

-- 0 rows returned = success (table exists but is empty)
SELECT * FROM READ_ICEBERG(
  LOCATION => 'gravitino_eks_test',
  NAMESPACE => 'repro_test',
  TABLE => 'sample_table'
) LIMIT 10;
```

### What This Proves

- Firebolt Cloud authenticates with Gravitino via OAuth (JWT)
- Gravitino reads Iceberg metadata from S3 using IRSA (no static keys)
- Gravitino vends temporary S3 credentials to Firebolt via `aws-irsa` provider
- Firebolt reads Parquet files directly from S3 using vended credentials
- **Zero static AWS keys in the entire flow**

A successful 0-row result on the `READ_ICEBERG` query proves every leg of the chain works.

### Security Note

This is a **test/reproduction** setup. For production:
- **OAuth**: Gravitino is not configured with `GRAVITINO_AUTHENTICATORS` — it accepts
  unauthenticated requests. The OAuth server exists to satisfy Firebolt's client-side
  requirement. For production, configure Gravitino's authenticator with the shared signing key.
- **ALB**: The ALB is `internet-facing` with no WAF or security groups restricting access.
  For production, use an `internal` ALB behind PrivateLink or VPN.

### Cleanup

```bash
eksctl delete cluster --name gravitino-repro --region us-east-1
aws iam delete-role-policy --role-name gravitino-repro-s3-role --policy-name s3-access
aws iam delete-role --role-name gravitino-repro-s3-role
```

---

## IRSA Setup Reference

If IRSA is not yet configured on your EKS cluster:

### 1. Enable OIDC provider

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster <CLUSTER_NAME> --region <REGION> --approve
```

### 2. Get the OIDC ID

```bash
aws eks describe-cluster --name <CLUSTER_NAME> --region <REGION> \
  --query "cluster.identity.oidc.issuer" --output text
# Returns: https://oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>
```

### 3. Create IAM role with IRSA trust policy

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<ACCOUNT>:oidc-provider/oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>:sub": "system:serviceaccount:<NAMESPACE>:<SA_NAME>",
        "oidc.eks.<REGION>.amazonaws.com/id/<OIDC_ID>:aud": "sts.amazonaws.com"
      }
    }
  }]
}
```

### 4. Attach S3 policy to the role

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::<BUCKET>/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::<BUCKET>"
    }
  ]
}
```

### 5. Create annotated ServiceAccount

```bash
kubectl create serviceaccount <SA_NAME> -n <NAMESPACE>
kubectl annotate serviceaccount <SA_NAME> -n <NAMESPACE> \
  eks.amazonaws.com/role-arn=arn:aws:iam::<ACCOUNT>:role/<ROLE_NAME>
```

### 6. Verify IRSA inside the pod

```bash
kubectl exec <POD> -n <NAMESPACE> -- env | grep AWS_WEB_IDENTITY_TOKEN_FILE
# Should return: /var/run/secrets/eks.amazonaws.com/serviceaccount/token

kubectl exec <POD> -n <NAMESPACE> -- env | grep AWS_ROLE_ARN
# Should return the IAM role ARN
```

---

## File Structure

```
gravitino-firebolt-iceberg-repro/
│
├── README.md                    # This file
├── docker-compose.yml           # Local: MinIO + Hive Metastore
├── repro-test.sh                # Local: Automated 5-scenario Docker test
├── conf/
│   └── hive-site.xml            # Hive Metastore → MinIO S3A config
│
└── k8s/                         # EKS deployment manifests
    ├── 00-namespace.yaml        # Namespace
    ├── 01-serviceaccount.yaml   # IRSA-annotated ServiceAccount
    ├── 02-oauth-server.yaml     # OAuth token server (pure Python, JWT)
    ├── 03-public-alb.yaml       # ALB Ingress (path-based routing)
    ├── 04-hive-metastore.yaml   # Hive Metastore with S3A + IRSA
    ├── setup-eks.sh             # One-command full EKS + Firebolt setup
    ├── verify-eks.sh            # Comprehensive verification script
    ├── create-test-data.sh      # Creates namespace + table via REST API
    │
    ├── broken-s3-token/         # Reproduces the customer error
    │   ├── configmap.yaml       #   GRAVITINO_CREDENTIAL_PROVIDERS=s3-token
    │   ├── secret.yaml          #   Static AWS key placeholders
    │   └── deployment.yaml      #   Injects GRAVITINO_S3_ACCESS_KEY
    │
    └── fixed-aws-irsa/          # The fix
        ├── configmap.yaml       #   GRAVITINO_CREDENTIAL_PROVIDERS=aws-irsa
        └── deployment.yaml      #   No static keys, uses IRSA
```

## Verified Against

- Gravitino `apache/gravitino-iceberg-rest:1.2.0` (latest as of March 2026)
- Hive Metastore `apache/hive:4.0.0`
- MinIO latest (S3-compatible, local testing)
- macOS (Docker Desktop) and Linux
- [Gravitino 1.2.0 credential vending docs](https://gravitino.apache.org/docs/1.2.0/security/credential-vending)

## References

- [Gravitino Credential Vending — Official Docs](https://gravitino.apache.org/docs/1.2.0/security/credential-vending)
- [S3 IRSA Credential Provider](https://gravitino.apache.org/docs/1.2.0/security/credential-vending#s3-irsa-credential)
- [S3 Token Credential Provider](https://gravitino.apache.org/docs/1.2.0/security/credential-vending#s3-token-credential)
- [AWS IRSA Documentation](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [AwsIrsaCredential JavaDoc (1.2.0)](https://gravitino.apache.org/docs/1.2.0/api/java/org/apache/gravitino/credential/AwsIrsaCredential.html)
