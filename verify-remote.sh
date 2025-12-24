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
HELLOWORLD_V2_IMAGE="docker.io/istio/examples-helloworld-v2:1.0"
CURL_IMAGE="docker.io/curlimages/curl:8.16.0"

echo ""
echo "============================================================================"
log_info "Deploy to Remote, Verify from Primary"
echo "============================================================================"
echo ""

# ============================================================================
# Load images into kind clusters
# ============================================================================
log_step "Loading images into kind clusters..."

for img in "${HELLOWORLD_V2_IMAGE}" "${CURL_IMAGE}"; do
    if ! podman image exists "${img}"; then
        log_info "Pulling ${img}..."
        podman pull "${img}"
    fi
done

log_info "Loading images into cluster1..."
kind load docker-image "${CURL_IMAGE}" --name cluster1

log_info "Loading images into cluster2..."
kind load docker-image "${HELLOWORLD_V2_IMAGE}" --name cluster2

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
# Deploy HelloWorld service to both clusters (for DNS resolution)
# ============================================================================
log_step "Deploying HelloWorld service to both clusters..."
kubectl apply --context="${CTX_CLUSTER1}" -f "${SAMPLES_URL}/helloworld/helloworld.yaml" -l service=helloworld -n "${NAMESPACE}"
kubectl apply --context="${CTX_CLUSTER2}" -f "${SAMPLES_URL}/helloworld/helloworld.yaml" -l service=helloworld -n "${NAMESPACE}"

# ============================================================================
# Deploy HelloWorld V2 to cluster2 (remote) only
# ============================================================================
log_step "Deploying HelloWorld V2 to cluster2 (remote)..."
kubectl apply --context="${CTX_CLUSTER2}" -f "${SAMPLES_URL}/helloworld/helloworld.yaml" -l version=v2 -n "${NAMESPACE}"

log_info "Waiting for helloworld-v2 to be ready..."
kubectl wait --context="${CTX_CLUSTER2}" --for=condition=available deployment/helloworld-v2 -n "${NAMESPACE}" --timeout=120s

# ============================================================================
# Deploy curl to cluster1 (primary) only
# ============================================================================
log_step "Deploying curl to cluster1 (primary)..."
kubectl apply --context="${CTX_CLUSTER1}" -f "${SAMPLES_URL}/curl/curl.yaml" -n "${NAMESPACE}"

log_info "Waiting for curl pod to be ready..."
kubectl wait --context="${CTX_CLUSTER1}" --for=condition=available deployment/curl -n "${NAMESPACE}" --timeout=120s

# ============================================================================
# Verify cross-cluster traffic
# ============================================================================
echo ""
echo "============================================================================"
log_info "Verifying Cross-Cluster Traffic"
echo "============================================================================"
echo ""

log_step "Sending requests from cluster1 (primary) to HelloWorld on cluster2 (remote)..."
echo "All responses should be from v2:"
echo ""

for i in {1..6}; do
    kubectl exec --context="${CTX_CLUSTER1}" -n "${NAMESPACE}" -c curl \
        "$(kubectl get pod --context="${CTX_CLUSTER1}" -n "${NAMESPACE}" -l app=curl -o jsonpath='{.items[0].metadata.name}')" \
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
echo "If you see v2 responses, cross-cluster connectivity is working!"
echo ""
echo "To clean up:"
echo "  kubectl delete namespace ${NAMESPACE} --context=${CTX_CLUSTER1}" --validate=false
echo "  kubectl delete namespace ${NAMESPACE} --context=${CTX_CLUSTER2}" --validate=false
echo ""
