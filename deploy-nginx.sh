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
NAMESPACE="sample"
ISTIO_VERSION="${ISTIO_VERSION:-1.28.2}"
SAMPLES_URL="https://raw.githubusercontent.com/istio/istio/release-${ISTIO_VERSION%.*}/samples"

# Images used by the samples
HELLOWORLD_V1_IMAGE="docker.io/istio/examples-helloworld-v1:1.0"
HELLOWORLD_V2_IMAGE="docker.io/istio/examples-helloworld-v2:1.0"
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

for img in "${HELLOWORLD_V1_IMAGE}" "${HELLOWORLD_V2_IMAGE}" "${CURL_IMAGE}" "${NGINX_IMAGE}"; do
    if ! podman image exists "${img}"; then
        log_info "Pulling ${img}..."
        podman pull "${img}"
    fi
done

log_info "Loading images into cluster1..."
kind load docker-image "${HELLOWORLD_V1_IMAGE}" "${CURL_IMAGE}" --name cluster1

log_info "Loading images into cluster2..."
kind load docker-image "${HELLOWORLD_V2_IMAGE}" "${CURL_IMAGE}" "${NGINX_IMAGE}" --name cluster2

echo ""

# ============================================================================
# Verify multi-cluster connectivity
# ============================================================================
log_step "Verifying multi-cluster connectivity..."
istioctl remote-clusters --context="${CTX_CLUSTER1}"
echo ""

# ============================================================================
# Create sample namespace on both clusters
# ============================================================================
log_step "Creating namespace '${NAMESPACE}' on both clusters..."
kubectl create --context="${CTX_CLUSTER1}" namespace "${NAMESPACE}" 2>/dev/null || true
kubectl create --context="${CTX_CLUSTER2}" namespace "${NAMESPACE}" 2>/dev/null || true

kubectl label --context="${CTX_CLUSTER1}" namespace "${NAMESPACE}" istio-injection=enabled --overwrite
kubectl label --context="${CTX_CLUSTER2}" namespace "${NAMESPACE}" istio-injection=enabled --overwrite

# ============================================================================
# Deploy HelloWorld service to both clusters
# ============================================================================
log_step "Deploying HelloWorld service to both clusters..."
kubectl apply --context="${CTX_CLUSTER1}" -f "${SAMPLES_URL}/helloworld/helloworld.yaml" -l service=helloworld -n "${NAMESPACE}"
kubectl apply --context="${CTX_CLUSTER2}" -f "${SAMPLES_URL}/helloworld/helloworld.yaml" -l service=helloworld -n "${NAMESPACE}"

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
# Deploy nginx to cluster2 only (remote-only workload)
# ============================================================================
log_step "Deploying nginx to cluster2 (remote cluster only)..."

cat <<EOF | kubectl apply -f - --context="${CTX_CLUSTER2}"
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
        image: nginx:latest
        ports:
        - containerPort: 80
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
# Deploy curl to both clusters
# ============================================================================
log_step "Deploying curl to both clusters..."
kubectl apply --context="${CTX_CLUSTER1}" -f "${SAMPLES_URL}/curl/curl.yaml" -n "${NAMESPACE}"
kubectl apply --context="${CTX_CLUSTER2}" -f "${SAMPLES_URL}/curl/curl.yaml" -n "${NAMESPACE}"

log_info "Waiting for curl pods to be ready..."
kubectl wait --context="${CTX_CLUSTER1}" --for=condition=available deployment/curl -n "${NAMESPACE}" --timeout=120s
kubectl wait --context="${CTX_CLUSTER2}" --for=condition=available deployment/curl -n "${NAMESPACE}" --timeout=120s

# ============================================================================
# Verify cross-cluster traffic
# ============================================================================
echo ""
echo "============================================================================"
log_info "Verifying Cross-Cluster Traffic"
echo "============================================================================"
echo ""

log_step "Sending requests from cluster1 to HelloWorld service..."
echo "Responses should alternate between v1 and v2:"
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

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================================================"
log_info "Verification Complete!"
echo "============================================================================"
echo ""
echo "If you see responses from both v1 and v2, cross-cluster load balancing is working!"
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
EOF

echo ""
echo "============================================================================"
log_info "Browser Access URLs"
echo "============================================================================"
echo ""
echo "  http://helloworld.localhost/hello  - Load balanced across both clusters (v1 + v2)"
echo "  http://nginx.localhost             - Remote cluster only (cluster2)"
echo ""
echo "The nginx service demonstrates accessing workloads that ONLY exist on the"
echo "remote cluster (cluster2) through the primary cluster's ingress gateway."
echo ""
echo "To clean up:"
echo "  kubectl delete namespace ${NAMESPACE} --context=${CTX_CLUSTER1}"
echo "  kubectl delete namespace ${NAMESPACE} --context=${CTX_CLUSTER2}"
echo ""
