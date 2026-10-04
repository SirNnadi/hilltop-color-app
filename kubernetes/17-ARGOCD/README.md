# ArgoCD

## The problem with Helm alone

In the previous section (`16-HELM`) we built a Helm chart for color-app and
learned how to install, upgrade, and roll back releases. Helm solved the
problem of templating and packaging — but it still requires a human to run
`helm upgrade` every time something changes.

Think about what that means in practice:

- A developer merges a PR that bumps the image tag
- Someone has to remember to run `helm upgrade` against the right cluster
- If they forget, production is running old code
- If someone runs `kubectl edit deployment` directly on the cluster, the
  change is invisible — Helm has no idea it happened
- There is no audit trail of who deployed what and when
- Rolling back means finding the right revision number and running another command

This is the **gap Helm leaves open** — it is a deployment tool, not a
continuous delivery tool. It does not watch anything. It does not self-correct.
It does not enforce that the cluster matches Git.

## What ArgoCD adds on top of Helm

ArgoCD sits inside the cluster and watches your Git repository continuously.
When it detects that the desired state in Git differs from the live state in
the cluster — whether because a new commit was pushed or because someone
manually changed something — it acts.

```
Without ArgoCD (Helm only)
──────────────────────────
Developer pushes code
        │
        ▼
CI builds image → pushes to ECR
        │
        ▼
  !! Someone must remember to run helm upgrade !!
        │
        ▼
Cluster updated (maybe, if they remembered)


With ArgoCD (Helm + GitOps)
───────────────────────────
Developer pushes code
        │
        ▼
CI builds image → pushes to ECR
        │
        ▼
CI updates image.tag in helm/color-app/env/values-prod.yaml → commits to Git
        │
        ▼
ArgoCD detects the change in Git automatically
        │
        ▼
ArgoCD runs helm template with the env values file → applies diff to EKS
        │
        ▼
New pods roll out — zero manual intervention
```

ArgoCD does not replace Helm. It uses Helm under the hood to render the
templates — it just removes the human from the loop.

| Problem with Helm alone | How ArgoCD solves it |
|---|---|
| Must remember to run `helm upgrade` | ArgoCD syncs automatically on every Git push |
| No visibility into live vs desired state | UI shows exact diff between Git and cluster |
| Manual `kubectl` changes go undetected | Drift is detected and auto-corrected (selfHeal) |
| Rollback requires knowing revision numbers | Rollback = `git revert` — full history in Git |
| No audit trail | Every change is a Git commit with author and timestamp |
| Cluster credentials needed in CI pipeline | ArgoCD runs inside the cluster — no outbound secrets |

## What is ArgoCD?

ArgoCD is a declarative, GitOps-based continuous delivery tool for Kubernetes.
It watches a Git repository and automatically reconciles the live cluster state
with the desired state defined in that repo.

The core principle is: **Git is the single source of truth**. Every deployment,
rollback, and config change is a Git commit — giving you a full audit trail,
peer review via pull requests, and instant rollback by reverting a commit.

### Core concepts

| Term | What it means |
|---|---|
| **Application** | An ArgoCD object that links a Git repo path to a cluster namespace |
| **Sync** | The act of applying Git state to the cluster |
| **Drift** | When live cluster state differs from Git state |
| **Self-heal** | ArgoCD automatically corrects drift without human intervention |
| **App of Apps** | A parent Application that manages child Applications |
| **Project** | A logical grouping of Applications with RBAC and source restrictions |

---

## Prerequisites

- EKS cluster running (`color-app-cluster-prod`)
- `kubectl` configured and pointing at the cluster
- Helm installed (see `16-HELM/README.md`)
- AWS CLI configured

```bash
kubectl config current-context
# Should show: color-app-cluster-prod
```

---

## Step 1 — Install ArgoCD

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n argocd \
  --timeout=120s

kubectl get pods -n argocd
```

---

## Step 2 — Install the ArgoCD CLI

### Windows (Chocolatey)
```powershell
choco install argocd-cli
```

### macOS
```bash
brew install argocd
```

### Linux
```bash
curl -sSL -o argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd && sudo mv argocd /usr/local/bin/
```

---

## Step 3 — Access the ArgoCD UI

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open: **https://localhost:8080**

### Get the initial admin password

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath="{.data.password}" | base64 --decode
echo
```

### Login via CLI

```bash
argocd login localhost:8080 \
  --username admin \
  --password <paste-password-here> \
  --insecure
```

### Change the admin password and delete the initial secret

```bash
argocd account update-password \
  --current-password <initial-password> \
  --new-password <your-strong-password>

kubectl delete secret argocd-initial-admin-secret -n argocd
```

---

## Step 4 — Expose ArgoCD via LoadBalancer (optional)

```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "LoadBalancer"}}'

kubectl get svc argocd-server -n argocd
```

---

## Step 5 — Connect the Git repository (UI)

1. Click **Settings** (gear icon) in the left sidebar
2. Click **Repositories**
3. Click **+ Connect Repo**
4. Fill in:
   - Connection method: `HTTPS`
   - Type: `git`
   - Project: `default`
   - Repository URL: `https://github.com/CHAFAH/hilltop-color-app.git`
   - If private repo — add Username and Password (GitHub PAT)
5. Click **Connect**
6. Status should show **Successful** ✅

---

## Step 6 — Deploy color-app with ArgoCD (UI)

The chart lives at `helm/color-app/` with environment-specific values files
under `helm/color-app/env/`. The ArgoCD Application manifest is at
`kubernetes/17-ARGOCD/color-app-application.yaml`.

### Option A: Create via the UI

1. Click **Applications** in the left sidebar
2. Click **+ New App**
3. Fill in the **General** section:
   - Application Name: `color-app`
   - Project Name: `default`
   - Sync Policy: `Automatic`
   - Check ✅ **Prune Resources**
   - Check ✅ **Self Heal**
4. Fill in the **Source** section:
   - Repository URL: `https://github.com/CHAFAH/hilltop-color-app.git`
   - Revision: `main`
   - Path: `helm/color-app`
   - Helm values files: `env/values-prod.yaml`
5. Fill in the **Destination** section:
   - Cluster URL: `https://kubernetes.default.svc`
   - Namespace: `production`
6. Under **Sync Options** check ✅ **Auto-Create Namespace**
7. Click **Create**

ArgoCD will immediately start syncing — the app card should turn green showing **Healthy** and **Synced**.

### Option B: Apply the manifest directly

```bash
kubectl apply -f kubernetes/17-ARGOCD/color-app-application.yaml
```

### Application manifest

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: color-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default

  source:
    repoURL: https://github.com/CHAFAH/hilltop-color-app.git
    targetRevision: main
    path: helm/color-app
    helm:
      valueFiles:
        - env/values-prod.yaml

  destination:
    server: https://kubernetes.default.svc
    namespace: production

  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

---

## Step 7 — Verify the deployment

```bash
argocd app get color-app
argocd app wait color-app --sync

kubectl get all -n production
kubectl get externalsecret -n production
kubectl get secret color-app-secret -n production
kubectl rollout status deployment/color-app-deployment -n production
```

---

## Step 8 — Deploy a new version (the GitOps way)

Never run `kubectl set image` manually. Update the values file in Git:

```bash
# 1. Edit the image tag in the env values file
#    helm/color-app/env/values-prod.yaml
#    Change: tag: "v1"
#    To:     tag: "v2"

# 2. Commit and push
git add helm/color-app/env/values-prod.yaml
git commit -m "deploy color-app:v2 to production"
git push origin main

# 3. ArgoCD detects the change within 3 minutes or trigger immediately
argocd app sync color-app

# 4. Watch the rollout
argocd app wait color-app --health
kubectl rollout status deployment/color-app-deployment -n production
```

> Any change to configmap, externalsecret, secretstore, pvc, or serviceaccount
> also triggers an automatic rolling restart via checksum annotations in the
> deployment pod template.

---

## Step 9 — Roll back a deployment

### Via ArgoCD CLI

```bash
argocd app history color-app
argocd app rollback color-app 1
```

### Via Git (preferred in production)

```bash
git revert HEAD
git push origin main
# ArgoCD syncs the revert automatically
```

---

## Step 10 — Upgrade ArgoCD itself

```bash
# Via kubectl manifests
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

---

## Useful ArgoCD CLI commands

```bash
argocd app list
argocd app get color-app
argocd app sync color-app
argocd app sync color-app --wait
argocd app diff color-app
argocd app logs color-app
argocd app history color-app
argocd app rollback color-app 1
argocd app delete color-app
```

---

## Production hardening checklist

- [ ] Change the default admin password and delete `argocd-initial-admin-secret`
- [ ] Create named user accounts — disable the `admin` account for day-to-day use
- [ ] Create ArgoCD **Projects** to restrict which repos and namespaces each team can deploy to
- [ ] Enable SSO (GitHub OAuth, Okta, etc.) via `argocd-cm` ConfigMap
- [ ] Use **App of Apps** pattern to manage all Applications from a single root Application
- [ ] Use `targetRevision: <tag>` instead of `main` in production to pin to a known-good commit
- [ ] Enable notifications (Slack, PagerDuty) via the ArgoCD Notifications controller
- [ ] Store the ArgoCD Application manifests in Git — ArgoCD manages itself

---

## Full setup summary

```bash
# 1. Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=argocd-server -n argocd --timeout=120s

# 2. Get initial password
kubectl get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath="{.data.password}" | base64 --decode && echo

# 3. Port-forward and login
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
argocd login localhost:8080 --username admin --password <password> --insecure

# 4. Change password and clean up
argocd account update-password
kubectl delete secret argocd-initial-admin-secret -n argocd

# 5. Connect the repo and create the app via the UI
#    Settings → Repositories → Connect Repo
#    Applications → New App (see Step 5 and Step 6 above)

# 6. Watch it sync
argocd app wait color-app --sync
kubectl get all -n production

# 8. Deploy new version — update image.tag in values-prod.yaml, commit, push, then:
argocd app sync color-app

# 9. Roll back if needed
argocd app rollback color-app 1
```
