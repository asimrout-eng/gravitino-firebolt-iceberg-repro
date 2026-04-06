# Gravitino 1.2.0 — S3 Credential Provider Reproduction

Reproduction of the `The AWS Access Key Id you provided does not exist in our records`
error when using Apache Gravitino 1.2.0 as an Iceberg REST catalog with AWS S3 and IRSA
(IAM Roles for Service Accounts) in EKS.

## Root Cause (TL;DR)

The customer configured `credential-providers=s3-token`, which **requires static IAM keys**.
The correct provider for EKS/IRSA is `credential-providers=aws-irsa`, available since
Gravitino 1.0.0 — [official docs](https://gravitino.apache.org/docs/1.2.0/security/credential-vending#s3-irsa-credential).

Additionally, the Helm chart's `rewrite_config.py` writes `s3-access-key-id = ` (blank)
into the config when `GRAVITINO_S3_ACCESS_KEY` is set to an empty string, overriding the
AWS default credential chain.

## Credential Providers in Gravitino 1.2.0

| Provider | Config value | Use case | Requires static keys? | Since |
|---|---|---|---|---|
| **S3 IRSA** | `aws-irsa` | EKS pods with IRSA | **No** — uses `AWS_WEB_IDENTITY_TOKEN_FILE` | 1.0.0 |
| S3 Token | `s3-token` | STS AssumeRole with static keys | **Yes** — `s3-access-key-id` + `s3-secret-access-key` | 0.8.0 |
| S3 Secret Key | `s3-secret-key` | Passthrough static keys | **Yes** | 0.8.0 |

Source: https://gravitino.apache.org/docs/1.2.0/security/credential-vending

## What This Repo Tests

Five scenarios that isolate and reproduce the problem:

| # | Scenario | Credential Provider | S3 Keys | Expected Result |
|---|---|---|---|---|
| 1 | Explicit static keys | none | `GRAVITINO_S3_ACCESS_KEY=minioadmin` | **PASS** — metadata read works |
| 2 | Blank keys (customer bug) | none | `GRAVITINO_S3_ACCESS_KEY=""` | **FAIL** — blank key written to config |
| 3 | No keys, default chain | none | env `AWS_ACCESS_KEY_ID` only | **PASS** — falls back to SDK chain |
| 4 | s3-token + temp keys | `s3-token` | `GRAVITINO_S3_ACCESS_KEY=ASIA...` | **FAIL** — no session token support |
| 5 | aws-irsa (correct fix) | `aws-irsa` | None | **FAIL locally** (no EKS) / **PASS in EKS** |

## Prerequisites

- Docker + Docker Compose
- ~2 GB free disk (MinIO, Hive Metastore, Gravitino images)
- Port 19000, 19001, 19083, 19201 free

## Quick Start

```bash
# Clone and enter the directory
cd gravitino-repro

# Start base services (MinIO + Hive Metastore)
docker compose up -d
# Wait ~45 seconds for Hive Metastore to initialize

# Run the full reproduction
./repro-test.sh

# Cleanup
docker compose down -v
```

## Understanding the `rewrite_config.py` Problem

Inside the `apache/gravitino-iceberg-rest:1.2.0` Docker image, a Python script at
`/root/gravitino-iceberg-rest-server/bin/rewrite_config.py` runs at container startup.
It maps environment variables to config properties:

```python
env_map = {
    "GRAVITINO_S3_ACCESS_KEY": "s3-access-key-id",
    "GRAVITINO_S3_SECRET_KEY": "s3-secret-access-key",
    # ... other mappings
}

for k, v in env_map.items():
    if k in os.environ:          # checks key EXISTS, not if value is non-empty
        update_config(config_map, v, os.environ[k])
```

When the Helm chart renders `GRAVITINO_S3_ACCESS_KEY: ""` (empty string), the env var
**exists** in the container's environment. The script writes `s3-access-key-id = ` (blank)
into the config. This blank value overrides the AWS SDK default credential chain, causing
S3 requests to fail.

## The `s3-token` vs `aws-irsa` Difference

### Why `s3-token` fails with IRSA

The `s3-token` provider (class: `S3TokenGenerator`) internally creates an STS client using
the **explicit** `s3-access-key-id` and `s3-secret-access-key` from the config. There is
no config property for `s3-session-token`, so temporary credentials (IRSA, STS sessions)
cannot be used — the STS `AssumeRole` call fails without the session token.

### Why `aws-irsa` works with IRSA

The `aws-irsa` provider (class: `AwsIrsaCredentialGenerator`) reads the
`AWS_WEB_IDENTITY_TOKEN_FILE` environment variable injected by EKS IRSA and uses
`StsClient` with web identity token authentication. No static keys needed.

Verified error when running `aws-irsa` outside EKS:

```
Caused by: java.lang.IllegalStateException:
  AWS_WEB_IDENTITY_TOKEN_FILE environment variable is not set.
  Ensure IRSA is properly configured in your EKS cluster.
```

This confirms `aws-irsa` explicitly uses the IRSA mechanism and will work in EKS.

## Fix for the Customer

### Option A: Use `aws-irsa` credential provider (recommended)

Set in the Gravitino Helm values or environment:

```yaml
# Helm values.yaml
gravitino:
  credentialProviders: "aws-irsa"
  s3:
    roleArn: "arn:aws:iam::<ACCOUNT>:role/gravitino-firebolt-role"
    region: "ap-south-1"
```

Or as environment variables on the pod:

```bash
GRAVITINO_CREDENTIAL_PROVIDERS=aws-irsa
GRAVITINO_S3_ROLE_ARN=arn:aws:iam::<ACCOUNT>:role/gravitino-firebolt-role
GRAVITINO_S3_REGION=ap-south-1
```

**Important**: Do NOT set `GRAVITINO_S3_ACCESS_KEY` or `GRAVITINO_S3_SECRET_KEY` at all.
Remove them entirely from the Helm template / ConfigMap / environment.

### Option B: Remove blank env vars (partial fix)

If only metadata reads are needed (no credential vending to Firebolt):

1. Remove `GRAVITINO_S3_ACCESS_KEY` and `GRAVITINO_S3_SECRET_KEY` entirely from the
   Helm chart templates and pod environment
2. Gravitino's S3FileIO will use the AWS SDK default credential chain (which picks up
   IRSA tokens in EKS)

This fixes metadata reads but does NOT enable credential vending to Firebolt.

### IRSA Prerequisites (EKS)

1. EKS cluster with OIDC provider configured
2. IAM role with S3 access and trust policy for the OIDC provider
3. Kubernetes ServiceAccount annotated with the IAM role ARN
4. Pod using that ServiceAccount

```bash
# Verify IRSA is working inside the Gravitino pod
kubectl exec -it <gravitino-pod> -n gravitino -- env | grep AWS_WEB_IDENTITY
# Should show: AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token

kubectl exec -it <gravitino-pod> -n gravitino -- env | grep AWS_ROLE_ARN
# Should show the IAM role ARN
```

## Deploy on EKS (Full End-to-End Proof)

The `k8s/` directory contains ready-to-deploy manifests for testing on an actual EKS
cluster with IRSA. This is the only way to fully prove credential vending works.

### Structure

```
k8s/
├── 00-namespace.yaml           # gravitino-repro namespace
├── 01-serviceaccount.yaml      # ServiceAccount with IRSA annotation
├── broken-s3-token/            # ❌ Original manifests (reproduces the error)
│   ├── configmap.yaml          #    GRAVITINO_CREDENTIAL_PROVIDERS=s3-token
│   ├── secret.yaml             #    Static AWS key placeholders
│   └── deployment.yaml         #    Injects GRAVITINO_S3_ACCESS_KEY from Secret
├── fixed-aws-irsa/             # ✅ Corrected manifests (the fix)
│   ├── configmap.yaml          #    GRAVITINO_CREDENTIAL_PROVIDERS=aws-irsa
│   └── deployment.yaml         #    No static keys, uses IRSA
└── verify-eks.sh               # Verification script
```

### Prerequisites

1. EKS cluster with OIDC provider enabled
2. IAM role with S3 access + trust policy for the OIDC provider
3. `kubectl` configured for the cluster

### Steps

```bash
# 1. Edit placeholders in the manifests
#    - 01-serviceaccount.yaml: set your IAM role ARN
#    - configmap.yaml: set your S3 bucket, region, Hive Metastore URI, role ARN

# 2. Deploy the namespace + service account
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-serviceaccount.yaml

# 3a. To REPRODUCE the error (broken):
kubectl apply -f k8s/broken-s3-token/

# 3b. To TEST the fix (correct):
kubectl apply -f k8s/fixed-aws-irsa/

# 4. Verify
bash k8s/verify-eks.sh
```

### What to Expect

**With `broken-s3-token/`**: The pod starts, but loading a table with
`X-Iceberg-Access-Delegation: vended-credentials` returns:
```
The AWS Access Key Id you provided does not exist in our records
```

**With `fixed-aws-irsa/`**: The pod starts, and credential vending returns temporary
S3 credentials scoped to the table path. The verify script should show:
```
✅ SUCCESS (HTTP 200) — credential vending works!
```

## File Structure

```
gravitino-repro/
├── README.md                   # This file
├── docker-compose.yml          # Local: MinIO + Hive Metastore
├── repro-test.sh               # Local: Automated 5-scenario Docker test
├── conf/
│   └── hive-site.xml           # Hive Metastore → MinIO S3A config
└── k8s/                        # EKS: Ready-to-deploy K8s manifests
    ├── 00-namespace.yaml
    ├── 01-serviceaccount.yaml
    ├── broken-s3-token/        # ❌ Reproduces the error
    ├── fixed-aws-irsa/         # ✅ The fix
    └── verify-eks.sh           # Verification script
```

## Verified Against

- Gravitino `apache/gravitino-iceberg-rest:1.2.0` (latest release as of March 2026)
- Hive Metastore `apache/hive:4.0.0`
- MinIO latest (S3-compatible storage for local testing)
- macOS (Docker Desktop) and Linux
