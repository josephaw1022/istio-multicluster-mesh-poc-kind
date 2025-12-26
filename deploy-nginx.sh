#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

CTX_CLUSTER1="kind-cluster1"
CTX_CLUSTER2="kind-cluster2"
CTX_CLUSTER3="kind-cluster3"
NAMESPACE="sample"
ISTIO_VERSION="${ISTIO_VERSION:-1.28.2}"
SAMPLES_URL="https://raw.githubusercontent.com/istio/istio/release-${ISTIO_VERSION%.*}/samples"

# Images used by the samples
HELLOWORLD_V1_IMAGE="docker.io/istio/examples-helloworld-v1:1.0"
HELLOWORLD_V2_IMAGE="docker.io/istio/examples-helloworld-v2:1.0"
HELLOWORLD_V3_IMAGE="docker.io/istio/examples-helloworld-v1:1.0"  # Using v1 image for v3
CURL_IMAGE="docker.io/curlimages/curl:8.16.0"
NGINX_IMAGE="docker.io/library/nginx:latest"

echo ""
echo "============================================================================"
log_info "Verifying Istio Multi-Cluster Installation"
echo "============================================================================"
echo ""

# ============================================================================
# Load images into kind clusters
# ============================================================================
log_step "Loading images into kind clusters..."

for img in "${HELLOWORLD_V1_IMAGE}" "${HELLOWORLD_V2_IMAGE}" "${HELLOWORLD_V3_IMAGE}" "${CURL_IMAGE}" "${NGINX_IMAGE}"; do
    if ! podman image exists "${img}"; then
        log_info "Pulling ${img}..."
        podman pull "${img}"
    fi
done

log_info "Loading images into cluster1..."
kind load docker-image "${HELLOWORLD_V1_IMAGE}" --name cluster1
kind load docker-image "${CURL_IMAGE}" --name cluster1
kind load docker-image "${NGINX_IMAGE}" --name cluster1

log_info "Loading images into cluster2..."
kind load docker-image "${HELLOWORLD_V2_IMAGE}" --name cluster2
kind load docker-image "${CURL_IMAGE}" --name cluster2
kind load docker-image "${NGINX_IMAGE}" --name cluster2

log_info "Loading images into cluster3..."
kind load docker-image "${HELLOWORLD_V3_IMAGE}" --name cluster3
kind load docker-image "${CURL_IMAGE}" --name cluster3
kind load docker-image "${NGINX_IMAGE}" --name cluster3

echo ""

# ============================================================================
# Verify multi-cluster connectivity
# ============================================================================
log_step "Verifying multi-cluster connectivity..."
istioctl remote-clusters --context="${CTX_CLUSTER1}"
echo ""

# ============================================================================
# Create sample namespace on all clusters
# ============================================================================
log_step "Creating namespace '${NAMESPACE}' on all clusters..."
kubectl create --context="${CTX_CLUSTER1}" namespace "${NAMESPACE}" 2>/dev/null || true
kubectl create --context="${CTX_CLUSTER2}" namespace "${NAMESPACE}" 2>/dev/null || true
kubectl create --context="${CTX_CLUSTER3}" namespace "${NAMESPACE}" 2>/dev/null || true

kubectl label --context="${CTX_CLUSTER1}" namespace "${NAMESPACE}" istio-injection=enabled --overwrite
kubectl label --context="${CTX_CLUSTER2}" namespace "${NAMESPACE}" istio-injection=enabled --overwrite
kubectl label --context="${CTX_CLUSTER3}" namespace "${NAMESPACE}" istio-injection=enabled --overwrite

# ============================================================================
# Deploy HelloWorld service to all clusters
# ============================================================================
log_step "Deploying HelloWorld service to all clusters..."
kubectl apply --context="${CTX_CLUSTER1}" -f "${SAMPLES_URL}/helloworld/helloworld.yaml" -l service=helloworld -n "${NAMESPACE}"
kubectl apply --context="${CTX_CLUSTER2}" -f "${SAMPLES_URL}/helloworld/helloworld.yaml" -l service=helloworld -n "${NAMESPACE}"
kubectl apply --context="${CTX_CLUSTER3}" -f "${SAMPLES_URL}/helloworld/helloworld.yaml" -l service=helloworld -n "${NAMESPACE}"

# ============================================================================
# Deploy HelloWorld V1 to cluster1
# ============================================================================
log_step "Deploying HelloWorld V1 to cluster1..."
kubectl apply --context="${CTX_CLUSTER1}" -f "${SAMPLES_URL}/helloworld/helloworld.yaml" -l version=v1 -n "${NAMESPACE}"

log_info "Waiting for helloworld-v1 to be ready..."
kubectl wait --context="${CTX_CLUSTER1}" --for=condition=available deployment/helloworld-v1 -n "${NAMESPACE}" --timeout=120s

# ============================================================================
# Deploy HelloWorld V2 to cluster2
# ============================================================================
log_step "Deploying HelloWorld V2 to cluster2..."
kubectl apply --context="${CTX_CLUSTER2}" -f "${SAMPLES_URL}/helloworld/helloworld.yaml" -l version=v2 -n "${NAMESPACE}"

log_info "Waiting for helloworld-v2 to be ready..."
kubectl wait --context="${CTX_CLUSTER2}" --for=condition=available deployment/helloworld-v2 -n "${NAMESPACE}" --timeout=120s

# ============================================================================
# Deploy HelloWorld V3 to cluster3 (custom deployment since v3 doesn't exist in samples)
# ============================================================================
log_step "Deploying HelloWorld V3 to cluster3..."

cat <<EOF | kubectl apply -f - --context="${CTX_CLUSTER3}"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: helloworld-v3
  namespace: ${NAMESPACE}
  labels:
    app: helloworld
    version: v3
spec:
  replicas: 1
  selector:
    matchLabels:
      app: helloworld
      version: v3
  template:
    metadata:
      labels:
        app: helloworld
        version: v3
    spec:
      containers:
      - name: helloworld
        env:
        - name: SERVICE_VERSION
          value: v3
        image: ${HELLOWORLD_V3_IMAGE}
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 5000
EOF

log_info "Waiting for helloworld-v3 to be ready..."
kubectl wait --context="${CTX_CLUSTER3}" --for=condition=available deployment/helloworld-v3 -n "${NAMESPACE}" --timeout=120s

# ============================================================================
# Deploy nginx to cluster2 only (remote-only workload)
# ============================================================================
log_step "Deploying nginx to cluster2 (remote cluster only)..."

cat <<EOF | kubectl apply -f - --context="${CTX_CLUSTER2}"
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-html
  namespace: ${NAMESPACE}
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head>
        <title>Nginx - Cluster 2</title>
        <style>
            body {
                font-family: Arial, sans-serif;
                display: flex;
                justify-content: center;
                align-items: center;
                height: 100vh;
                margin: 0;
                background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                color: white;
            }
            .container {
                text-align: center;
                padding: 40px;
                background: rgba(255,255,255,0.1);
                border-radius: 10px;
                backdrop-filter: blur(10px);
            }
            h1 { font-size: 2.5em; margin-bottom: 10px; }
            p { font-size: 1.2em; opacity: 0.9; }
            .cluster { color: #ffd700; font-weight: bold; }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>&#128640; Nginx is Running!</h1>
            <p>This nginx deployment is running on <span class="cluster">Cluster 2</span></p>
            <p>(Remote Cluster)</p>
        </div>
    </body>
    </html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: ${NGINX_IMAGE}
        ports:
        - containerPort: 80
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
      volumes:
      - name: html
        configMap:
          name: nginx-html
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: ${NAMESPACE}
spec:
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
EOF

log_info "Waiting for nginx to be ready on cluster2..."
kubectl wait --context="${CTX_CLUSTER2}" --for=condition=available deployment/nginx -n "${NAMESPACE}" --timeout=120s

# Create nginx service on cluster1 for DNS resolution (service without pods)
log_step "Creating nginx service on cluster1 for DNS resolution..."
cat <<EOF | kubectl apply -f - --context="${CTX_CLUSTER1}"
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: ${NAMESPACE}
spec:
  ports:
  - port: 80
    targetPort: 80
EOF

# ============================================================================
# Deploy nginx-alt to cluster3 (second remote-only workload)
# ============================================================================
log_step "Deploying nginx-alt to cluster3 (remote cluster only)..."

cat <<EOF | kubectl apply -f - --context="${CTX_CLUSTER3}"
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-alt-html
  namespace: ${NAMESPACE}
data:
  index.html: |
    <!DOCTYPE html>
    <html>
    <head>
        <title>Nginx - Cluster 3</title>
        <style>
            body {
                font-family: Arial, sans-serif;
                display: flex;
                justify-content: center;
                align-items: center;
                height: 100vh;
                margin: 0;
                background: linear-gradient(135deg, #11998e 0%, #38ef7d 100%);
                color: white;
            }
            .container {
                text-align: center;
                padding: 40px;
                background: rgba(255,255,255,0.1);
                border-radius: 10px;
                backdrop-filter: blur(10px);
            }
            h1 { font-size: 2.5em; margin-bottom: 10px; }
            p { font-size: 1.2em; opacity: 0.9; }
            .cluster { color: #ffd700; font-weight: bold; }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>&#128640; Nginx is Running!</h1>
            <p>This nginx deployment is running on <span class="cluster">Cluster 3</span></p>
            <p>(Remote Cluster)</p>
        </div>
    </body>
    </html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-alt
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-alt
  template:
    metadata:
      labels:
        app: nginx-alt
    spec:
      containers:
      - name: nginx
        image: ${NGINX_IMAGE}
        ports:
        - containerPort: 80
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
      volumes:
      - name: html
        configMap:
          name: nginx-alt-html
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-alt
  namespace: ${NAMESPACE}
spec:
  selector:
    app: nginx-alt
  ports:
  - port: 80
    targetPort: 80
EOF

log_info "Waiting for nginx-alt to be ready on cluster3..."
kubectl wait --context="${CTX_CLUSTER3}" --for=condition=available deployment/nginx-alt -n "${NAMESPACE}" --timeout=120s

# Create nginx-alt service on cluster1 for DNS resolution (service without pods)
log_step "Creating nginx-alt service on cluster1 for DNS resolution..."
cat <<EOF | kubectl apply -f - --context="${CTX_CLUSTER1}"
apiVersion: v1
kind: Service
metadata:
  name: nginx-alt
  namespace: ${NAMESPACE}
spec:
  ports:
  - port: 80
    targetPort: 80
EOF

# ============================================================================
# Deploy curl to all clusters
# ============================================================================
log_step "Deploying curl to all clusters..."
kubectl apply --context="${CTX_CLUSTER1}" -f "${SAMPLES_URL}/curl/curl.yaml" -n "${NAMESPACE}"
kubectl apply --context="${CTX_CLUSTER2}" -f "${SAMPLES_URL}/curl/curl.yaml" -n "${NAMESPACE}"
kubectl apply --context="${CTX_CLUSTER3}" -f "${SAMPLES_URL}/curl/curl.yaml" -n "${NAMESPACE}"

log_info "Waiting for curl pods to be ready..."
kubectl wait --context="${CTX_CLUSTER1}" --for=condition=available deployment/curl -n "${NAMESPACE}" --timeout=120s
kubectl wait --context="${CTX_CLUSTER2}" --for=condition=available deployment/curl -n "${NAMESPACE}" --timeout=120s
kubectl wait --context="${CTX_CLUSTER3}" --for=condition=available deployment/curl -n "${NAMESPACE}" --timeout=120s

# ============================================================================
# Verify cross-cluster traffic
# ============================================================================
echo ""
echo "============================================================================"
log_info "Verifying Cross-Cluster Traffic"
echo "============================================================================"
echo ""

log_step "Sending requests from cluster1 to HelloWorld service..."
echo "Responses should alternate between v1, v2, and v3:"
echo ""

for i in {1..6}; do
    kubectl exec --context="${CTX_CLUSTER1}" -n "${NAMESPACE}" -c curl \
        "$(kubectl get pod --context="${CTX_CLUSTER1}" -n "${NAMESPACE}" -l app=curl -o jsonpath='{.items[0].metadata.name}')" \
        -- curl -sS helloworld.sample:5000/hello 2>/dev/null || echo "Request $i: waiting for mesh sync..."
    sleep 1
done

echo ""
log_step "Sending requests from cluster2 to HelloWorld service..."
echo ""

for i in {1..6}; do
    kubectl exec --context="${CTX_CLUSTER2}" -n "${NAMESPACE}" -c curl \
        "$(kubectl get pod --context="${CTX_CLUSTER2}" -n "${NAMESPACE}" -l app=curl -o jsonpath='{.items[0].metadata.name}')" \
        -- curl -sS helloworld.sample:5000/hello 2>/dev/null || echo "Request $i: waiting for mesh sync..."
    sleep 1
done

echo ""
log_step "Sending requests from cluster3 to HelloWorld service..."
echo ""

for i in {1..6}; do
    kubectl exec --context="${CTX_CLUSTER3}" -n "${NAMESPACE}" -c curl \
        "$(kubectl get pod --context="${CTX_CLUSTER3}" -n "${NAMESPACE}" -l app=curl -o jsonpath='{.items[0].metadata.name}')" \
        -- curl -sS helloworld.sample:5000/hello 2>/dev/null || echo "Request $i: waiting for mesh sync..."
    sleep 1
done

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================================================"
log_info "Verification Complete!"
echo "============================================================================"
echo ""
echo "If you see responses from v1, v2, and v3, cross-cluster load balancing is working!"
echo ""
echo "============================================================================"
log_info "Creating VirtualService for browser access..."
echo "============================================================================"

cat <<EOF | kubectl apply -f - --context="${CTX_CLUSTER1}"
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: helloworld-vs
  namespace: ${NAMESPACE}
spec:
  hosts:
    - "helloworld.localhost"
  gateways:
    - istio-system/localhost-gateway
  http:
    - route:
        - destination:
            host: helloworld.${NAMESPACE}.svc.cluster.local
            port:
              number: 5000
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: nginx-vs
  namespace: ${NAMESPACE}
spec:
  hosts:
    - "nginx.localhost"
  gateways:
    - istio-system/localhost-gateway
  http:
    - route:
        - destination:
            host: nginx.${NAMESPACE}.svc.cluster.local
            port:
              number: 80
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: nginx-alt-vs
  namespace: ${NAMESPACE}
spec:
  hosts:
    - "nginx-alt.localhost"
  gateways:
    - istio-system/localhost-gateway
  http:
    - route:
        - destination:
            host: nginx-alt.${NAMESPACE}.svc.cluster.local
            port:
              number: 80
EOF

echo ""
echo "============================================================================"
log_info "Browser Access URLs"
echo "============================================================================"
echo ""
echo "  http://helloworld.localhost/hello  - Load balanced across all clusters (v1 + v2 + v3)"
echo "  http://nginx.localhost             - Remote cluster only (cluster2)"
echo "  http://nginx-alt.localhost         - Remote cluster only (cluster3)"
echo ""
echo "The nginx services demonstrate accessing workloads that ONLY exist on the"
echo "remote clusters (cluster2 and cluster3) through the primary cluster's ingress gateway."
echo ""
echo "To clean up:"
echo " task clean-nginx"
echo ""
