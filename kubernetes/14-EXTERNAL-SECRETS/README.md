# External Secrets Operator — AWS Secrets Manager

## What is it?

The External Secrets Operator (ESO) syncs secrets from AWS Secrets Manager into
native Kubernetes Secrets. Pods consume them exactly like a normal Secret — but
the values live in AWS, not in the cluster.

```
AWS Secrets Manager
      │
      │  (ESO polls every refreshInterval)
      ▼
ExternalSecret  ──►  Kubernetes Secret  ──►  Pod (env vars or volume)
```

**Why use it instead of a plain Kubernetes Secret?**
- Values are stored and rotated in AWS — not base64-encoded in a YAML file
- You only list the **key names** in the manifest — values are never in Git
- Automatic refresh: when you rotate a secret in AWS, the K8s Secret updates
  within the refresh interval without redeploying the pod

---

## Step 1 — Install the External Secrets Operator via Helm

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true

# Verify pods are running
kubectl get pods -n external-secrets
```

---

## Step 2 — Create the secret in AWS Secrets Manager

```bash
aws secretsmanager create-secret \
  --name color-app/prod \
  --region us-east-1 \
  --secret-string '{
    "SECRET_KEY": "landmark-prod-secret-2024",
    "DB_PASSWORD": "super-secure-db-pass",
    "API_KEY": "my-api-key-12345"
  }'
```

---

## Step 3 — Create the IAM policy for ESO

```bash
cat > eso-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:us-east-1:075120018043:secret:color-app/*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name ESOSecretsManagerPolicy \
  --policy-document file://eso-policy.json
```

---

## Step 4 — Create IRSA role for ESO ServiceAccount

```bash
# Get the OIDC provider URL
OIDC=$(aws eks describe-cluster --name color-app-cluster-prod \
  --query "cluster.identity.oidc.issuer" --output text | sed 's|https://||')

# Create trust policy
cat > trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::075120018043:oidc-provider/${OIDC}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC}:sub": "system:serviceaccount:color-app:eso-sa",
        "${OIDC}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name color-app-eso-role \
  --assume-role-policy-document file://trust.json

aws iam attach-role-policy \
  --role-name color-app-eso-role \
  --policy-arn arn:aws:iam::075120018043:policy/ESOSecretsManagerPolicy
```

---

## Step 5 — Apply the manifests

```bash
kubectl create namespace color-app --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f serviceaccount.yaml   # creates eso-sa with IRSA annotation
kubectl apply -f secretstore.yaml      # connects ESO to AWS Secrets Manager
kubectl apply -f externalsecret.yaml   # defines which keys to pull
```

---

## Step 6 — Verify

```bash
# Check ESO synced successfully
kubectl get externalsecret color-app-external-secret -n color-app
# READY column should show: True
# STATUS should show:       SecretSynced

# Check the Kubernetes Secret was created
kubectl get secret color-app-secret -n color-app

# Decode and verify values
kubectl get secret color-app-secret -n color-app \
  -o jsonpath='{.data.SECRET_KEY}' | base64 -d

kubectl get secret color-app-secret -n color-app \
  -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
```

---

## Step 7 — Test auto-refresh (rotation demo)

```bash
# Rotate the secret in AWS
aws secretsmanager update-secret \
  --secret-id color-app/prod \
  --secret-string '{
    "SECRET_KEY": "rotated-secret-2025",
    "DB_PASSWORD": "new-db-pass-rotated",
    "API_KEY": "new-api-key-rotated"
  }'

# Wait 1 minute (refreshInterval), then check the K8s secret updated
kubectl get secret color-app-secret -n color-app \
  -o jsonpath='{.data.SECRET_KEY}' | base64 -d
# Output: rotated-secret-2025
```

> **Note:** Env var pods need a restart to pick up new values.
> Pods using a **volume mount** get the updated file automatically.

---

## Cleanup

```bash
kubectl delete -f externalsecret.yaml
kubectl delete -f secretstore.yaml
kubectl delete -f serviceaccount.yaml
aws secretsmanager delete-secret \
  --secret-id color-app/prod \
  --force-delete-without-recovery
aws iam detach-role-policy \
  --role-name color-app-eso-role \
  --policy-arn arn:aws:iam::075120018043:policy/ESOSecretsManagerPolicy
aws iam delete-role --role-name color-app-eso-role
aws iam delete-policy --policy-arn arn:aws:iam::075120018043:policy/ESOSecretsManagerPolicy
```
