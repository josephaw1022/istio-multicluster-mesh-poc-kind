#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Cluster context names
CTX_CLUSTER1="kind-cluster1"
CTX_CLUSTER2="kind-cluster2"

# Namespace for demo
NAMESPACE="demo"

# Nginx image
NGINX_IMAGE="nginx:latest"
CURL_IMAGE="curlimages/curl"

echo ""
echo "============================================================================"
log_info "Deploying Nginx on Remote Cluster (cluster2)"
echo "============================================================================"
echo ""

# ============================================================================
# STEP 0: Pull images locally with podman and load into cluster2
# ============================================================================
log_step "Checking and pulling container images..."

# Check if nginx image exists locally
if ! podman image exists "${NGINX_IMAGE}"; then
    log_info "Pulling ${NGINX_IMAGE} with podman..."
    podman pull "${NGINX_IMAGE}"
else
    log_info "Image ${NGINX_IMAGE} already exists locally"
fi

# Check if curl image exists locally
if ! podman image exists "${CURL_IMAGE}"; then
    log_info "Pulling ${CURL_IMAGE} with podman..."
    podman pull "${CURL_IMAGE}"
else
    log_info "Image ${CURL_IMAGE} already exists locally"
fi

log_step "Loading images into cluster2..."
kind load docker-image "${NGINX_IMAGE}" --name cluster2
kind load docker-image "${CURL_IMAGE}" --name cluster1

echo ""

# ============================================================================
# STEP 1: Create namespace on cluster2
# ============================================================================
log_step "Creating namespace '${NAMESPACE}' on cluster2..."
kubectl create namespace "${NAMESPACE}" --context="${CTX_CLUSTER2}" || true
kubectl label namespace "${NAMESPACE}" istio-injection=enabled --overwrite --context="${CTX_CLUSTER2}"

# ============================================================================
# STEP 2: Deploy nginx on cluster2
# ============================================================================
log_step "Deploying nginx on cluster2..."
cat <<EOF | kubectl apply -f - --context="${CTX_CLUSTER2}"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: ${NAMESPACE}
  labels:
    app: nginx
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
        version: v1
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
          name: http
        resources:
          requests:
            memory: "64Mi"
            cpu: "100m"
          limits:
            memory: "128Mi"
            cpu: "200m"
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: ${NAMESPACE}
  labels:
    app: nginx
spec:
  type: ClusterIP
  ports:
  - port: 80
    targetPort: 80
    protocol: TCP
    name: http
  selector:
    app: nginx
EOF

log_info "Waiting for nginx deployment to be ready on cluster2..."
kubectl wait --for=condition=available deployment/nginx -n "${NAMESPACE}" --timeout=120s --context="${CTX_CLUSTER2}"

# ============================================================================
# STEP 3: Create the same namespace on cluster1 for service discovery
# ============================================================================
log_step "Creating namespace '${NAMESPACE}' on cluster1 for service discovery..."
kubectl create namespace "${NAMESPACE}" --context="${CTX_CLUSTER1}" || true
kubectl label namespace "${NAMESPACE}" istio-injection=enabled --overwrite --context="${CTX_CLUSTER1}"

# ============================================================================
# STEP 4: Display deployment status
# ============================================================================
echo ""
log_info "Deployment Status on cluster2:"
kubectl get pods -n "${NAMESPACE}" --context="${CTX_CLUSTER2}"
echo ""
kubectl get svc -n "${NAMESPACE}" --context="${CTX_CLUSTER2}"

# ============================================================================
# STEP 5: Deploy a sleep pod on cluster1 to test connectivity
# ============================================================================
echo ""
log_step "Deploying sleep pod on cluster1 to test connectivity..."
cat <<EOF | kubectl apply -f - --context="${CTX_CLUSTER1}"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: sleep
  namespace: ${NAMESPACE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sleep
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sleep
  template:
    metadata:
      labels:
        app: sleep
    spec:
      serviceAccountName: sleep
      containers:
      - name: sleep
        image: curlimages/curl
        command: ["/bin/sleep", "infinity"]
        resources:
          requests:
            memory: "32Mi"
            cpu: "50m"
          limits:
            memory: "64Mi"
            cpu: "100m"
EOF

log_info "Waiting for sleep pod to be ready on cluster1..."
kubectl wait --for=condition=available deployment/sleep -n "${NAMESPACE}" --timeout=120s --context="${CTX_CLUSTER1}"

SLEEP_POD=$(kubectl get pod -n "${NAMESPACE}" --context="${CTX_CLUSTER1}" -l app=sleep -o jsonpath='{.items[0].metadata.name}')
log_info "Sleep pod: ${SLEEP_POD}"

# ============================================================================
# STEP 6: Test cross-cluster connectivity
# ============================================================================
echo ""
echo "============================================================================"
log_info "Testing Cross-Cluster Connectivity"
echo "============================================================================"
echo ""

log_step "Calling nginx service on cluster2 from sleep pod on cluster1..."
echo ""
log_info "Command: kubectl exec ${SLEEP_POD} -n ${NAMESPACE} --context=${CTX_CLUSTER1} -c sleep -- curl -s http://nginx.${NAMESPACE}.svc.cluster.local"
echo ""

kubectl exec "${SLEEP_POD}" -n "${NAMESPACE}" --context="${CTX_CLUSTER1}" -c sleep -- curl -s -m 10 http://nginx.${NAMESPACE}.svc.cluster.local || {
    log_warn "Initial connection failed, this is expected if Istio is still propagating service discovery."
    log_warn "Wait a few seconds and try again with the command above."
}

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================================================"
log_info "Deployment Complete!"
echo "============================================================================"
echo ""
echo "Nginx is running on cluster2 (remote cluster)"
echo "Sleep pod is running on cluster1 (primary cluster)"
echo ""
echo "To test connectivity from cluster1 to cluster2:"
echo "  kubectl exec ${SLEEP_POD} -n ${NAMESPACE} --context=${CTX_CLUSTER1} -c sleep -- curl -s http://nginx.${NAMESPACE}.svc.cluster.local"
echo ""
echo "To test with verbose output to see which cluster pod responds:"
echo "  kubectl exec ${SLEEP_POD} -n ${NAMESPACE} --context=${CTX_CLUSTER1} -c sleep -- curl -v http://nginx.${NAMESPACE}.svc.cluster.local 2>&1 | grep -i 'x-envoy'"
echo ""
echo "To check Istio proxy logs on the sleep pod:"
echo "  kubectl logs ${SLEEP_POD} -n ${NAMESPACE} --context=${CTX_CLUSTER1} -c istio-proxy"
echo ""
echo "To view nginx pods on cluster2:"
echo "  kubectl get pods -n ${NAMESPACE} --context=${CTX_CLUSTER2} -o wide"
echo ""
echo "To clean up:"
echo "  kubectl delete namespace ${NAMESPACE} --context=${CTX_CLUSTER1}"
echo "  kubectl delete namespace ${NAMESPACE} --context=${CTX_CLUSTER2}"
echo ""
