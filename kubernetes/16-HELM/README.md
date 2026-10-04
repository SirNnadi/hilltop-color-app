# Helm

## What is Helm?

Helm is the package manager for Kubernetes. Instead of managing 10 separate
YAML files (Deployment, Service, ConfigMap, Secret, HPA, etc.) and applying
them one by one, Helm bundles them into a single unit called a **chart**.
A chart is a folder of templated Kubernetes manifests driven by values files
that control every configurable value — image tag, replicas, namespace,
resource limits — from one place.

### Core concepts

| Term | What it means |
|---|---|
| **Chart** | A packaged Kubernetes application — a folder of templates + values |
| **Values file** | The file you pass per environment to configure the chart |
| **Release** | A named, running instance of a chart installed into the cluster |
| **Revision** | A numbered snapshot — every install or upgrade creates a new one |
| **Repository** | A remote index of pre-built charts (like npm or apt) |

---

## Install Helm locally

### Windows (Chocolatey)
```powershell
choco install kubernetes-helm
```

### macOS
```bash
brew install helm
```

### Linux
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

### Verify
```bash
helm version
```

---

## Chart location

The chart lives at `helm/color-app/` at the repo root — **not** inside `kubernetes/16-HELM/`.

```
hilltop-color-app/
└── helm/
    └── color-app/
        ├── Chart.yaml
        ├── charts/
        ├── templates/
        │   ├── _helpers.tpl
        │   ├── configmap.yaml
        │   ├── deployment.yaml
        │   ├── externalsecret.yaml
        │   ├── hpa.yaml
        │   ├── lb-service.yaml
        │   ├── NOTES.txt
        │   ├── pvc.yaml
        │   ├── secretstore.yaml
        │   └── serviceaccount.yaml
        └── env/
            ├── values-dev.yaml
            ├── values-stg.yaml
            └── values-prod.yaml
```

---

## Chart.yaml

```yaml
apiVersion: v2
name: color-app
description: Helm chart for the hilltop color-app
type: application
version: 0.1.0
appVersion: "v1"
```

---

## Environment values files

There is no root `values.yaml`. Each environment has its own fully self-contained
values file under `helm/color-app/env/`. You must always pass one with `-f`.

| File | Namespace | Replicas | Autoscaling | APP_COLOR | Secret path |
|---|---|---|---|---|---|
| `values-dev.yaml` | `develop` | 1 | disabled | green | `color-app/dev` |
| `values-stg.yaml` | `staging` | 2 | enabled (max 5) | yellow | `color-app/stg` |
| `values-prod.yaml` | `production` | 3 | enabled (max 10) | blue | `color-app/prod` |

Key values in each file:

```yaml
namespace: production          # controls namespace for ALL resources

image:
  repository: 075120018043.dkr.ecr.us-east-1.amazonaws.com/color-app
  tag: "v1"

serviceAccount:
  create: true
  name: "color-app"
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::075120018043:role/color-app-eso-role

externalSecret:
  region: us-east-1
  serviceAccountName: color-app-sa
  refreshInterval: 1m
  remoteKey: color-app/prod    # path in AWS Secrets Manager
  keys:
  - name: SECRET_KEY
  - name: DB_PASSWORD
  - name: API_KEY
```

---

## Templates overview

### Resources created (9 total)

| Template | Resource | Name |
|---|---|---|
| `serviceaccount.yaml` | ServiceAccount | `color-app-sa` |
| `configmap.yaml` | ConfigMap | `color-app-config` |
| `secretstore.yaml` | SecretStore | `color-app-secret-store` |
| `externalsecret.yaml` | ExternalSecret | `color-app-external-secret` |
| `pvc.yaml` | PersistentVolumeClaim | `color-app-pvc` |
| `lb-service.yaml` | Service (NLB) | `color-app-lb` |
| `deployment.yaml` | Deployment | `color-app-deployment` |
| `hpa.yaml` | HorizontalPodAutoscaler | `color-app-hpa` |

> `ingress.yaml` and `secret.yaml` were deleted — ingress is not used,
> secrets come exclusively from ESO.

### Secrets — ESO is the source of truth

There is no static Kubernetes `Secret` in this chart. Secrets are pulled from
AWS Secrets Manager by the ExternalSecret and written into `color-app-secret`
by the ESO controller:

```
AWS Secrets Manager (color-app/prod)
        │  SECRET_KEY, DB_PASSWORD, API_KEY
        ▼
ExternalSecret → creates → color-app-secret (Kubernetes Secret)
        ▼
Deployment reads all 3 keys via secretKeyRef
```

The `color-app-sa` ServiceAccount has an IRSA annotation pointing at
`color-app-eso-role` which has Secrets Manager read permissions.

### Auto-rollout on any config change

The deployment pod template includes checksums of all related objects.
Whenever any of these change and you run `helm upgrade`, the checksum
annotation changes → Kubernetes detects a pod spec diff → rolling restart
triggers automatically:

```yaml
annotations:
  checksum/config:      <sha256 of configmap.yaml>
  checksum/secret:      <sha256 of externalsecret.yaml>
  checksum/secretstore: <sha256 of secretstore.yaml>
  checksum/pvc:         <sha256 of pvc.yaml>
  checksum/sa:          <sha256 of serviceaccount.yaml>
```

---

## Validate the chart

```bash
cd hilltop-color-app/helm

# Lint
helm lint color-app/ -f color-app/env/values-prod.yaml

# Render templates locally
helm template color-app color-app/ -f color-app/env/values-prod.yaml

# Dry-run against the cluster
helm install color-app color-app/ \
  -f color-app/env/values-prod.yaml \
  --namespace production \
  --dry-run
```

---

## Install

```bash
cd hilltop-color-app/helm

helm install color-app color-app/ \
  -f color-app/env/values-prod.yaml \
  --namespace production \
  --create-namespace
```

> The chart manages the namespace via `--create-namespace` — there is no
> `namespace.yaml` template.

Verify:

```bash
helm list -n production
kubectl get all -n production
kubectl get externalsecret -n production
kubectl get secret color-app-secret -n production
```

---

## Upgrade

```bash
helm upgrade color-app color-app/ \
  -f color-app/env/values-prod.yaml \
  --namespace production
```

Check revision history:

```bash
helm history color-app -n production
```

---

## Roll back

```bash
# Roll back to previous revision
helm rollback color-app -n production

# Roll back to a specific revision
helm rollback color-app 1 -n production
```

---

## Uninstall

```bash
helm uninstall color-app -n production
kubectl delete namespace production
```

---

## Deploy per environment

```bash
# Dev
helm install color-app color-app/ \
  -f color-app/env/values-dev.yaml \
  --namespace develop \
  --create-namespace

# Staging
helm install color-app color-app/ \
  -f color-app/env/values-stg.yaml \
  --namespace staging \
  --create-namespace

# Production
helm install color-app color-app/ \
  -f color-app/env/values-prod.yaml \
  --namespace production \
  --create-namespace
```

---

## Full workflow summary

```bash
# 1. Install Helm
choco install kubernetes-helm

# 2. Navigate to the helm folder
cd hilltop-color-app/helm

# 3. Validate
helm lint color-app/ -f color-app/env/values-prod.yaml
helm template color-app color-app/ -f color-app/env/values-prod.yaml --no-hooks

# 4. Install
helm install color-app color-app/ \
  -f color-app/env/values-prod.yaml \
  --namespace production \
  --create-namespace

# 5. Verify
helm list -n production
kubectl get all -n production
kubectl get externalsecret -n production

# 6. Upgrade after changes
helm upgrade color-app color-app/ \
  -f color-app/env/values-prod.yaml \
  --namespace production

# 7. Check history
helm history color-app -n production

# 8. Roll back if needed
helm rollback color-app -n production
```
