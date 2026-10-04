# Monitoring

## The problem without monitoring

You have deployed color-app to production. Helm packaged it. ArgoCD keeps it
in sync with Git. But right now you are flying blind.

- How do you know if the app is actually serving traffic?
- How do you know if a pod crashed at 3am and restarted 10 times?
- How do you know if a node is running out of memory?
- How do you know if response times suddenly spiked after the v2 deploy?
- How do you know if the HPA scaled up to 8 replicas because of a traffic surge?

You don't. Not without monitoring.

Monitoring is the practice of continuously collecting, storing, and visualizing
data about your system so you can understand what is happening right now, what
happened in the past, and get alerted before something breaks completely.

---

## The three pillars of observability

Modern observability is built on three types of data. Each answers a different
question about your system.

### 1. Metrics

Metrics are **numbers measured over time**. They are lightweight, cheap to
store, and perfect for dashboards and alerting.

Examples:
- CPU usage: `node_cpu_seconds_total`
- Memory usage: `container_memory_usage_bytes`
- HTTP request rate: `http_requests_total`
- Pod restart count: `kube_pod_container_status_restarts_total`
- HPA replica count: `kube_horizontalpodautoscaler_status_current_replicas`

Metrics answer: **how much? how many? how fast?**

Tool in this stack: **Prometheus**

---

### 2. Logs

Logs are **text records of events** that happened inside your application or
infrastructure. Every time your app does something — handles a request, throws
an error, connects to a database — it writes a log line.

Examples:
```
[2026-09-30T10:00:01Z] INFO  GET /health 200 12ms
[2026-09-30T10:00:05Z] ERROR Failed to connect to DB: timeout after 30s
[2026-09-30T10:00:06Z] WARN  Retrying connection attempt 2/3
```

Logs answer: **what exactly happened and when?**

Tools: `kubectl logs`, Loki, CloudWatch Logs, Elasticsearch

> In this cluster the app already writes logs to stdout which Kubernetes
> captures. CloudWatch Container Insights can ship them to CloudWatch Logs.

---

### 3. Traces

Traces track a **single request as it flows through multiple services**. In a
microservices architecture a single user request might touch 5 different
services. A trace stitches all those hops together with timing so you can see
exactly where time was spent and where failures occurred.

```
User request → API Gateway (2ms)
                    → Auth Service (5ms)
                    → Color App (45ms)
                              → Database query (40ms) ← slow!
                    → Response (52ms total)
```

Traces answer: **where is the bottleneck? which service caused the failure?**

Tools: AWS X-Ray, Jaeger, Zipkin, OpenTelemetry

---

### 4. Events

Events are **discrete occurrences** in the Kubernetes cluster — a pod was
scheduled, a node became NotReady, an image pull failed, an HPA scaled up.

```bash
kubectl get events -n production --sort-by='.lastTimestamp'
```

Events answer: **what did Kubernetes do and why?**

---

### Summary — which tool for which signal

| Signal | What it is | Tool | Best for |
|---|---|---|---|
| **Metrics** | Numbers over time | Prometheus + Grafana | Dashboards, alerting, capacity planning |
| **Logs** | Text event records | Loki / CloudWatch | Debugging, audit trail |
| **Traces** | Request flow across services | X-Ray / Jaeger | Latency analysis, microservices debugging |
| **Events** | Kubernetes cluster events | kubectl / Grafana | Scheduling issues, crash loops |

---

## What we are monitoring in this cluster

For color-app on EKS we want visibility into:

| What | Why |
|---|---|
| Node CPU and memory | Know if nodes are under pressure before they crash |
| Pod CPU and memory | Know if a pod is hitting its resource limits |
| Pod restarts | Detect crash loops early |
| HPA replica count | See if autoscaling is working |
| Deployment rollout status | Confirm new versions rolled out cleanly |
| HTTP request rate and latency | Know if the app is serving traffic correctly |
| PVC usage | Know if storage is filling up |

---

## The monitoring stack — kube-prometheus-stack

We use the **kube-prometheus-stack** Helm chart which bundles everything
needed in a single install:

| Component | What it does |
|---|---|
| **Prometheus** | Scrapes and stores metrics from all cluster components |
| **Grafana** | Visualizes metrics in dashboards |
| **Alertmanager** | Sends alerts (Slack, email, PagerDuty) when rules fire |
| **kube-state-metrics** | Exposes Kubernetes object metrics (pods, deployments, HPA) |
| **node-exporter** | Exposes node-level metrics (CPU, memory, disk) per node |
| **Prometheus Operator** | Manages Prometheus config via Kubernetes CRDs |

---

## Prerequisites

- EKS cluster running (`color-app-cluster-prod`)
- `kubectl` configured and pointing at the cluster
- Helm installed
- Metrics Server installed (required for HPA — already done)

```bash
kubectl config current-context
helm version
kubectl get pods -n kube-system | grep metrics-server
```

---

## Step 1 — Install Metrics Server

The Metrics Server is required for `kubectl top` commands and for the HPA to
read CPU and memory metrics. Without it the HPA will show `unknown` targets
and pods cannot autoscale.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

Verify it is running:

```bash
kubectl get pods -n kube-system | grep metrics-server
# metrics-server-xxx   1/1   Running

kubectl get apiservice v1beta1.metrics.k8s.io
# NAME                     AVAILABLE
# v1beta1.metrics.k8s.io   True

# Test it works
kubectl top nodes
kubectl top pods -n production
```

> Already installed on `color-app-cluster-prod` — skip if `v1beta1.metrics.k8s.io` shows `AVAILABLE: True`.

---

## Step 2 — Add the Prometheus community Helm repo

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

---

## Step 3 — Create the monitoring namespace

```bash
kubectl create namespace monitoring
```

---

## Step 4 — Install kube-prometheus-stack

```bash
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword=admin123 \
  --set prometheus.prometheusSpec.retention=7d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=gp2 \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
  --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.storageClassName=gp2 \
  --set alertmanager.alertmanagerSpec.storage.volumeClaimTemplate.spec.resources.requests.storage=2Gi
```

> Change `grafana.adminPassword` to a strong password before running this.

Verify all pods are running:

```bash
kubectl get pods -n monitoring
# NAME                                                   READY   STATUS
# alertmanager-kube-prometheus-stack-alertmanager-0      2/2     Running
# kube-prometheus-stack-grafana-xxx                      3/3     Running
# kube-prometheus-stack-kube-state-metrics-xxx           1/1     Running
# kube-prometheus-stack-operator-xxx                     1/1     Running
# kube-prometheus-stack-prometheus-node-exporter-xxx     1/1     Running  ← one per node
# prometheus-kube-prometheus-stack-prometheus-0          2/2     Running
```

---

## Step 5 — Access Grafana

### Option A: Port-forward (local access)

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
```

Open: **http://localhost:3000**

- Username: `admin`
- Password: the value you set in `grafana.adminPassword`

### Option B: Expose via LoadBalancer

```bash
kubectl patch svc kube-prometheus-stack-grafana -n monitoring \
  -p '{"spec": {"type": "LoadBalancer"}}'

kubectl get svc kube-prometheus-stack-grafana -n monitoring
# Copy the EXTERNAL-IP and open in browser on port 80
```

---

## Step 6 — Import dashboards in Grafana

Grafana has a library of pre-built dashboards. Import these by ID:

### Nodes dashboard
1. Click **+** → **Import**
2. Enter ID: `1860` (Node Exporter Full)
3. Select Prometheus as the data source
4. Click **Import**

### Kubernetes cluster overview
1. Click **+** → **Import**
2. Enter ID: `315` (Kubernetes cluster monitoring)
3. Select Prometheus as the data source
4. Click **Import**

### Kubernetes pods
1. Click **+** → **Import**
2. Enter ID: `6417` (Kubernetes pods)
3. Select Prometheus as the data source
4. Click **Import**

### Kubernetes deployments
1. Click **+** → **Import**
2. Enter ID: `8588`
3. Select Prometheus as the data source
4. Click **Import**

---

## Step 7 — Monitor color-app specifically

### Check pod metrics

```bash
# CPU and memory per pod
kubectl top pods -n production

# CPU and memory per node
kubectl top nodes
```

### Check HPA status

```bash
kubectl get hpa -n production
# NAME             REFERENCE                        TARGETS   MINPODS   MAXPODS   REPLICAS
# color-app-hpa    Deployment/color-app-deployment  12%/60%   2         10        3
```

### Useful Prometheus queries (PromQL)

Run these in Grafana → Explore → select Prometheus:

```promql
# CPU usage per pod in production namespace
rate(container_cpu_usage_seconds_total{namespace="production"}[5m])

# Memory usage per pod in production namespace
container_memory_usage_bytes{namespace="production"}

# Pod restart count
kube_pod_container_status_restarts_total{namespace="production"}

# HPA current vs desired replicas
kube_horizontalpodautoscaler_status_current_replicas{namespace="production"}
kube_horizontalpodautoscaler_status_desired_replicas{namespace="production"}

# Node CPU usage %
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Node memory available
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100
```

---

## Step 8 — Set up an alert rule

Create an alert that fires when any pod in production restarts more than 3 times:

```bash
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: color-app-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack
spec:
  groups:
  - name: color-app
    rules:
    - alert: PodCrashLooping
      expr: kube_pod_container_status_restarts_total{namespace="production"} > 3
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Pod {{ \$labels.pod }} is crash looping"
        description: "Pod {{ \$labels.pod }} has restarted {{ \$value }} times"

    - alert: HighCPUUsage
      expr: rate(container_cpu_usage_seconds_total{namespace="production"}[5m]) > 0.8
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "High CPU on {{ \$labels.pod }}"
        description: "Pod {{ \$labels.pod }} CPU usage is above 80%"
EOF
```

View alerts in Grafana → Alerting → Alert Rules.

---

## Step 9 — Upgrade kube-prometheus-stack

```bash
helm repo update
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --reuse-values
```

---

## Step 10 — Uninstall

```bash
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete namespace monitoring
```

---

## Full setup summary

```bash
# 1. Install Metrics Server (skip if already installed)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl get apiservice v1beta1.metrics.k8s.io
# NAME                     AVAILABLE
# v1beta1.metrics.k8s.io   True

# 2. Add repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 3. Create namespace
kubectl create namespace monitoring

# 4. Install the stack
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword=<your-password> \
  --set prometheus.prometheusSpec.retention=7d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=gp2 \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi

# 4. Verify
kubectl get pods -n monitoring

# 5. Access Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
# Open http://localhost:3000 — admin / <your-password>

# 6. Import dashboards
# Node Exporter Full:          ID 1860
# Kubernetes cluster overview: ID 315
# Kubernetes pods:             ID 6417
# Kubernetes deployments:      ID 8588

# 7. Check color-app metrics
kubectl top pods -n production
kubectl top nodes
kubectl get hpa -n production
```
