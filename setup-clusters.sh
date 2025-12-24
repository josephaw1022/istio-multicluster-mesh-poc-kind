#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Cluster names (matching Istio docs naming convention)
CLUSTER1="cluster1"
CLUSTER2="cluster2"
CLUSTER3="cluster3"

# Context names (kind prefixes contexts with "kind-")
CTX_CLUSTER1="kind-${CLUSTER1}"
CTX_CLUSTER2="kind-${CLUSTER2}"
CTX_CLUSTER3="kind-${CLUSTER3}"

# Versions
ISTIO_VERSION="1.28.2"

# ============================================================================
# STEP 0: Pull Istio images if not present locally
# ============================================================================
log_info "Checking for Istio images locally..."
if ! podman image exists docker.io/istio/pilot:${ISTIO_VERSION}; then
    log_info "Pulling istio/pilot:${ISTIO_VERSION}..."
    podman pull docker.io/istio/pilot:${ISTIO_VERSION}
fi
if ! podman image exists docker.io/istio/proxyv2:${ISTIO_VERSION}; then
    log_info "Pulling istio/proxyv2:${ISTIO_VERSION}..."
    podman pull docker.io/istio/proxyv2:${ISTIO_VERSION}
fi

# ============================================================================
# STEP 1: Create cluster1 (Primary)
# ============================================================================
log_info "Creating ${CLUSTER1} Kind cluster..."
if kind get clusters | grep -q "^${CLUSTER1}$"; then
    log_warn "Cluster ${CLUSTER1} already exists, skipping creation"
else
    kind create cluster --name "${CLUSTER1}" --config kind-config.yaml
fi

# Load Istio images into cluster1
log_info "Loading Istio images into ${CLUSTER1}..."
kind load docker-image docker.io/istio/pilot:${ISTIO_VERSION} --name "${CLUSTER1}"
kind load docker-image docker.io/istio/proxyv2:${ISTIO_VERSION} --name "${CLUSTER1}"

# ============================================================================
# STEP 2: Create cluster2 (Remote)
# ============================================================================
log_info "Creating ${CLUSTER2} Kind cluster..."
if kind get clusters | grep -q "^${CLUSTER2}$"; then
    log_warn "Cluster ${CLUSTER2} already exists, skipping creation"
else
    kind create cluster --name "${CLUSTER2}" --config kind-config-remote.yaml
fi

# Load Istio images into cluster2
log_info "Loading Istio images into ${CLUSTER2}..."
kind load docker-image docker.io/istio/pilot:${ISTIO_VERSION} --name "${CLUSTER2}"
kind load docker-image docker.io/istio/proxyv2:${ISTIO_VERSION} --name "${CLUSTER2}"

# ============================================================================
# STEP 2.5: Create cluster3 (Remote)
# ============================================================================
log_info "Creating ${CLUSTER3} Kind cluster..."
if kind get clusters | grep -q "^${CLUSTER3}$"; then
    log_warn "Cluster ${CLUSTER3} already exists, skipping creation"
else
    kind create cluster --name "${CLUSTER3}" --config kind-config-remote.yaml
fi

# Load Istio images into cluster3
log_info "Loading Istio images into ${CLUSTER3}..."
kind load docker-image docker.io/istio/pilot:${ISTIO_VERSION} --name "${CLUSTER3}"
kind load docker-image docker.io/istio/proxyv2:${ISTIO_VERSION} --name "${CLUSTER3}"

# ============================================================================
# STEP 3: Pull and load MetalLB images
# ============================================================================
METALLB_VERSION="v0.14.9"
log_info "Checking for MetalLB images locally..."
if ! podman image exists quay.io/metallb/controller:${METALLB_VERSION}; then
    log_info "Pulling metallb/controller:${METALLB_VERSION}..."
    podman pull quay.io/metallb/controller:${METALLB_VERSION}
fi
if ! podman image exists quay.io/metallb/speaker:${METALLB_VERSION}; then
    log_info "Pulling metallb/speaker:${METALLB_VERSION}..."
    podman pull quay.io/metallb/speaker:${METALLB_VERSION}
fi
if ! podman image exists quay.io/frrouting/frr:9.1.0; then
    log_info "Pulling frrouting/frr:9.1.0..."
    podman pull quay.io/frrouting/frr:9.1.0
fi

log_info "Loading MetalLB images into ${CLUSTER1}..."
kind load docker-image quay.io/metallb/controller:${METALLB_VERSION} --name "${CLUSTER1}"
kind load docker-image quay.io/metallb/speaker:${METALLB_VERSION} --name "${CLUSTER1}"
kind load docker-image quay.io/frrouting/frr:9.1.0 --name "${CLUSTER1}"

log_info "Loading MetalLB images into ${CLUSTER2}..."
kind load docker-image quay.io/metallb/controller:${METALLB_VERSION} --name "${CLUSTER2}"
kind load docker-image quay.io/metallb/speaker:${METALLB_VERSION} --name "${CLUSTER2}"
kind load docker-image quay.io/frrouting/frr:9.1.0 --name "${CLUSTER2}"

log_info "Loading MetalLB images into ${CLUSTER3}..."
kind load docker-image quay.io/metallb/controller:${METALLB_VERSION} --name "${CLUSTER3}"
kind load docker-image quay.io/metallb/speaker:${METALLB_VERSION} --name "${CLUSTER3}"
kind load docker-image quay.io/frrouting/frr:9.1.0 --name "${CLUSTER3}"

# ============================================================================
# STEP 4: Install MetalLB on cluster1
# ============================================================================
log_info "Installing MetalLB on ${CLUSTER1}..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml --context "${CTX_CLUSTER1}"

log_info "Waiting for MetalLB controller to be ready on ${CLUSTER1}..."
kubectl wait --for=condition=available deployment/controller -n metallb-system --timeout=300s --context "${CTX_CLUSTER1}"
kubectl rollout status daemonset/speaker -n metallb-system --timeout=300s --context "${CTX_CLUSTER1}"

# ============================================================================
# STEP 5: Install MetalLB on cluster2
# ============================================================================
log_info "Installing MetalLB on ${CLUSTER2}..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml --context "${CTX_CLUSTER2}"

log_info "Waiting for MetalLB controller to be ready on ${CLUSTER2}..."
kubectl wait --for=condition=available deployment/controller -n metallb-system --timeout=300s --context "${CTX_CLUSTER2}"
kubectl rollout status daemonset/speaker -n metallb-system --timeout=300s --context "${CTX_CLUSTER2}"

# ============================================================================
# STEP 5.5: Install MetalLB on cluster3
# ============================================================================
log_info "Installing MetalLB on ${CLUSTER3}..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml --context "${CTX_CLUSTER3}"

log_info "Waiting for MetalLB controller to be ready on ${CLUSTER3}..."
kubectl wait --for=condition=available deployment/controller -n metallb-system --timeout=300s --context "${CTX_CLUSTER3}"
kubectl rollout status daemonset/speaker -n metallb-system --timeout=300s --context "${CTX_CLUSTER3}"

# ============================================================================
# STEP 6: Configure MetalLB IP pools for all clusters
# ============================================================================
log_info "Detecting kind network IP range..."
KIND_SUBNET=$(podman network inspect kind | jq -r '.[0].subnets[] | select(.subnet | test("^[0-9]")) | .subnet')

if [ -z "${KIND_SUBNET:-}" ]; then
    log_warn "Could not detect kind network subnet, using default 10.89.0.0/24"
    KIND_SUBNET="10.89.0.0/24"
fi

log_info "Kind network subnet: ${KIND_SUBNET}"
SUBNET_BASE=$(echo "${KIND_SUBNET}" | cut -d'/' -f1 | cut -d'.' -f1-3)

# cluster1 gets .200-.220, cluster2 gets .221-.240, cluster3 gets .241-.250
CLUSTER1_RANGE_START="${SUBNET_BASE}.200"
CLUSTER1_RANGE_END="${SUBNET_BASE}.220"
CLUSTER2_RANGE_START="${SUBNET_BASE}.221"
CLUSTER2_RANGE_END="${SUBNET_BASE}.240"
CLUSTER3_RANGE_START="${SUBNET_BASE}.241"
CLUSTER3_RANGE_END="${SUBNET_BASE}.250"

log_info "Configuring MetalLB on ${CLUSTER1} with range ${CLUSTER1_RANGE_START}-${CLUSTER1_RANGE_END}..."
cat <<EOF | kubectl apply -f - --context "${CTX_CLUSTER1}"
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${CLUSTER1_RANGE_START}-${CLUSTER1_RANGE_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - kind-pool
EOF

log_info "Configuring MetalLB on ${CLUSTER2} with range ${CLUSTER2_RANGE_START}-${CLUSTER2_RANGE_END}..."
cat <<EOF | kubectl apply -f - --context "${CTX_CLUSTER2}"
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${CLUSTER2_RANGE_START}-${CLUSTER2_RANGE_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - kind-pool
EOF

log_info "Configuring MetalLB on ${CLUSTER3} with range ${CLUSTER3_RANGE_START}-${CLUSTER3_RANGE_END}..."
cat <<EOF | kubectl apply -f - --context "${CTX_CLUSTER3}"
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${CLUSTER3_RANGE_START}-${CLUSTER3_RANGE_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - kind-pool
EOF

# ============================================================================
# STEP 6: Configure cluster1 as a primary (per Istio docs)
# ============================================================================
log_info "Configuring ${CLUSTER1} as primary..."

cat <<EOF | istioctl install --context="${CTX_CLUSTER1}" -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  components:
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          service:
            type: NodePort
            ports:
              - name: http2
                port: 80
                targetPort: 8080
                nodePort: 30080
              - name: https
                port: 443
                targetPort: 8443
                nodePort: 30443
  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster1
      network: network1
      externalIstiod: true
EOF

log_info "Waiting for istiod to be ready..."
kubectl rollout status deployment/istiod -n istio-system --timeout=300s --context "${CTX_CLUSTER1}"

# ============================================================================
# STEP 7: Install the east-west gateway in cluster1 (per Istio docs)
# ============================================================================
log_info "Installing east-west gateway on ${CLUSTER1}..."

cat <<EOF | istioctl --context="${CTX_CLUSTER1}" install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: eastwest
spec:
  revision: ""
  profile: empty
  components:
    ingressGateways:
      - name: istio-eastwestgateway
        label:
          istio: eastwestgateway
          app: istio-eastwestgateway
          topology.istio.io/network: network1
        enabled: true
        k8s:
          env:
            - name: ISTIO_META_REQUESTED_NETWORK_VIEW
              value: network1
          service:
            ports:
              - name: status-port
                port: 15021
                targetPort: 15021
              - name: tls
                port: 15443
                targetPort: 15443
              - name: tls-istiod
                port: 15012
                targetPort: 15012
              - name: tls-webhook
                port: 15017
                targetPort: 15017
  values:
    gateways:
      istio-ingressgateway:
        injectionTemplate: gateway
    global:
      network: network1
EOF

log_info "Waiting for east-west gateway to get an external IP..."
kubectl --context="${CTX_CLUSTER1}" wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' \
    svc/istio-eastwestgateway -n istio-system --timeout=300s || true

kubectl --context="${CTX_CLUSTER1}" get svc istio-eastwestgateway -n istio-system

# ============================================================================
# STEP 8: Expose the control plane in cluster1 (per Istio docs)
# ============================================================================
log_info "Exposing control plane in ${CLUSTER1}..."

cat <<EOF | kubectl apply --context="${CTX_CLUSTER1}" -n istio-system -f -
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: istiod-gateway
spec:
  selector:
    istio: eastwestgateway
  servers:
    - port:
        name: tls-istiod
        number: 15012
        protocol: tls
      tls:
        mode: PASSTHROUGH
      hosts:
        - "*"
    - port:
        name: tls-istiodwebhook
        number: 15017
        protocol: tls
      tls:
        mode: PASSTHROUGH
      hosts:
        - "*"
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: istiod-vs
spec:
  hosts:
  - "*"
  gateways:
  - istiod-gateway
  tls:
  - match:
    - port: 15012
      sniHosts:
      - "*"
    route:
    - destination:
        host: istiod.istio-system.svc.cluster.local
        port:
          number: 15012
  - match:
    - port: 15017
      sniHosts:
      - "*"
    route:
    - destination:
        host: istiod.istio-system.svc.cluster.local
        port:
          number: 443
EOF

# ============================================================================
# STEP 8.5: Expose services via east-west gateway
# ============================================================================
log_info "Exposing services via east-west gateway in ${CLUSTER1}..."

cat <<EOF | kubectl apply --context="${CTX_CLUSTER1}" -n istio-system -f -
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: cross-network-gateway
spec:
  selector:
    istio: eastwestgateway
  servers:
    - port:
        number: 15443
        name: tls
        protocol: TLS
      tls:
        mode: AUTO_PASSTHROUGH
      hosts:
        - "*.local"
EOF

# ============================================================================
# STEP 9: Set the control plane cluster for cluster2 (per Istio docs)
# ============================================================================
log_info "Setting control plane cluster for ${CLUSTER2}..."

kubectl --context="${CTX_CLUSTER2}" create namespace istio-system || true
kubectl --context="${CTX_CLUSTER2}" annotate namespace istio-system \
    topology.istio.io/controlPlaneClusters=cluster1 --overwrite

# ============================================================================
# STEP 10: Configure cluster2 as a remote (per Istio docs)
# ============================================================================
log_info "Getting discovery address from ${CLUSTER1}'s east-west gateway..."

DISCOVERY_ADDRESS=$(kubectl \
    --context="${CTX_CLUSTER1}" \
    -n istio-system get svc istio-eastwestgateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

log_info "Discovery address: ${DISCOVERY_ADDRESS}"

log_info "Configuring ${CLUSTER2} as remote..."

cat <<EOF | istioctl install --context="${CTX_CLUSTER2}" -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: remote
  values:
    istiodRemote:
      injectionPath: /inject/cluster/cluster2/net/network2
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster2
      network: network2
      remotePilotAddress: ${DISCOVERY_ADDRESS}
EOF

# ============================================================================
# STEP 11: Attach cluster2 as a remote cluster of cluster1 (per Istio docs)
# ============================================================================
log_info "Attaching ${CLUSTER2} as remote cluster of ${CLUSTER1}..."

# Get cluster2's control-plane IP (not localhost) so cluster1's istiod can reach it
CLUSTER2_API_SERVER="https://$(podman network inspect kind | jq -r '.[0].containers | to_entries[] | select(.value.name == "cluster2-control-plane") | .value.interfaces.eth0.subnets[] | select(.ipnet | test("^10")) | .ipnet' | cut -d'/' -f1):6443"

log_info "Using cluster2 API server: ${CLUSTER2_API_SERVER}"

istioctl create-remote-secret \
    --context="${CTX_CLUSTER2}" \
    --name=cluster2 \
    --server="${CLUSTER2_API_SERVER}" | \
    kubectl apply -f - --context="${CTX_CLUSTER1}"

# ============================================================================
# STEP 11.5: Install east-west gateway on cluster2 (for bidirectional traffic)
# ============================================================================
log_info "Installing east-west gateway on ${CLUSTER2}..."

cat <<EOF | istioctl --context="${CTX_CLUSTER2}" install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: eastwest
spec:
  revision: ""
  profile: empty
  components:
    ingressGateways:
      - name: istio-eastwestgateway
        label:
          istio: eastwestgateway
          app: istio-eastwestgateway
          topology.istio.io/network: network2
        enabled: true
        k8s:
          env:
            - name: ISTIO_META_REQUESTED_NETWORK_VIEW
              value: network2
          service:
            ports:
              - name: status-port
                port: 15021
                targetPort: 15021
              - name: tls
                port: 15443
                targetPort: 15443
              - name: tls-istiod
                port: 15012
                targetPort: 15012
              - name: tls-webhook
                port: 15017
                targetPort: 15017
  values:
    gateways:
      istio-ingressgateway:
        injectionTemplate: gateway
    global:
      network: network2
EOF

log_info "Waiting for east-west gateway to get an external IP on ${CLUSTER2}..."
kubectl --context="${CTX_CLUSTER2}" wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' \
    svc/istio-eastwestgateway -n istio-system --timeout=300s || true

kubectl --context="${CTX_CLUSTER2}" get svc istio-eastwestgateway -n istio-system

# ============================================================================
# STEP 11.6: Expose services via east-west gateway on cluster2
# ============================================================================
log_info "Exposing services via east-west gateway in ${CLUSTER2}..."

cat <<EOF | kubectl apply --context="${CTX_CLUSTER2}" -n istio-system -f -
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: cross-network-gateway
spec:
  selector:
    istio: eastwestgateway
  servers:
    - port:
        number: 15443
        name: tls
        protocol: TLS
      tls:
        mode: AUTO_PASSTHROUGH
      hosts:
        - "*.local"
EOF

# ============================================================================
# STEP 12: Set the control plane cluster for cluster3 (per Istio docs)
# ============================================================================
log_info "Setting control plane cluster for ${CLUSTER3}..."

kubectl --context="${CTX_CLUSTER3}" create namespace istio-system || true
kubectl --context="${CTX_CLUSTER3}" annotate namespace istio-system \
    topology.istio.io/controlPlaneClusters=cluster1 --overwrite

# ============================================================================
# STEP 12.1: Configure cluster3 as a remote (per Istio docs)
# ============================================================================
log_info "Configuring ${CLUSTER3} as remote..."

cat <<EOF | istioctl install --context="${CTX_CLUSTER3}" -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: remote
  values:
    istiodRemote:
      injectionPath: /inject/cluster/cluster3/net/network3
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster3
      network: network3
      remotePilotAddress: ${DISCOVERY_ADDRESS}
EOF

# ============================================================================
# STEP 12.2: Attach cluster3 as a remote cluster of cluster1 (per Istio docs)
# ============================================================================
log_info "Attaching ${CLUSTER3} as remote cluster of ${CLUSTER1}..."

# Get cluster3's control-plane IP (not localhost) so cluster1's istiod can reach it
CLUSTER3_API_SERVER="https://$(podman network inspect kind | jq -r '.[0].containers | to_entries[] | select(.value.name == "cluster3-control-plane") | .value.interfaces.eth0.subnets[] | select(.ipnet | test("^10")) | .ipnet' | cut -d'/' -f1):6443"

log_info "Using cluster3 API server: ${CLUSTER3_API_SERVER}"

istioctl create-remote-secret \
    --context="${CTX_CLUSTER3}" \
    --name=cluster3 \
    --server="${CLUSTER3_API_SERVER}" | \
    kubectl apply -f - --context="${CTX_CLUSTER1}"

# ============================================================================
# STEP 12.3: Install east-west gateway on cluster3 (for bidirectional traffic)
# ============================================================================
log_info "Installing east-west gateway on ${CLUSTER3}..."

cat <<EOF | istioctl --context="${CTX_CLUSTER3}" install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: eastwest
spec:
  revision: ""
  profile: empty
  components:
    ingressGateways:
      - name: istio-eastwestgateway
        label:
          istio: eastwestgateway
          app: istio-eastwestgateway
          topology.istio.io/network: network3
        enabled: true
        k8s:
          env:
            - name: ISTIO_META_REQUESTED_NETWORK_VIEW
              value: network3
          service:
            ports:
              - name: status-port
                port: 15021
                targetPort: 15021
              - name: tls
                port: 15443
                targetPort: 15443
              - name: tls-istiod
                port: 15012
                targetPort: 15012
              - name: tls-webhook
                port: 15017
                targetPort: 15017
  values:
    gateways:
      istio-ingressgateway:
        injectionTemplate: gateway
    global:
      network: network3
EOF

log_info "Waiting for east-west gateway to get an external IP on ${CLUSTER3}..."
kubectl --context="${CTX_CLUSTER3}" wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' \
    svc/istio-eastwestgateway -n istio-system --timeout=300s || true

kubectl --context="${CTX_CLUSTER3}" get svc istio-eastwestgateway -n istio-system

# ============================================================================
# STEP 12.4: Expose services via east-west gateway on cluster3
# ============================================================================
log_info "Exposing services via east-west gateway in ${CLUSTER3}..."

cat <<EOF | kubectl apply --context="${CTX_CLUSTER3}" -n istio-system -f -
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: cross-network-gateway
spec:
  selector:
    istio: eastwestgateway
  servers:
    - port:
        number: 15443
        name: tls
        protocol: TLS
      tls:
        mode: AUTO_PASSTHROUGH
      hosts:
        - "*.local"
EOF

# ============================================================================
# STEP 13: Verify Installation
# ============================================================================
log_info "Verifying multi-cluster installation..."

echo ""
log_info "${CLUSTER1} (Primary) Status:"
kubectl get pods -n istio-system --context "${CTX_CLUSTER1}"

echo ""
log_info "${CLUSTER2} (Remote) Status:"
kubectl get pods -n istio-system --context "${CTX_CLUSTER2}"

echo ""
log_info "${CLUSTER3} (Remote) Status:"
kubectl get pods -n istio-system --context "${CTX_CLUSTER3}"

echo ""
log_info "Verifying remote clusters..."
istioctl remote-clusters --context="${CTX_CLUSTER1}"

# ============================================================================
# STEP 14: Enable Sidecar Injection
# ============================================================================
log_info "Enabling sidecar injection on default namespace for all clusters..."
kubectl label namespace default istio-injection=enabled --overwrite --context "${CTX_CLUSTER1}"
kubectl label namespace default istio-injection=enabled --overwrite --context "${CTX_CLUSTER2}"
kubectl label namespace default istio-injection=enabled --overwrite --context "${CTX_CLUSTER3}"

# ============================================================================
# STEP 14: Create Gateway for *.localhost
# ============================================================================
log_info "Creating Gateway for *.localhost on ${CLUSTER1}..."

cat <<EOF | kubectl apply -f - --context "${CTX_CLUSTER1}"
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: localhost-gateway
  namespace: istio-system
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 80
        name: http
        protocol: HTTP
      hosts:
        - "*.localhost"
EOF

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "============================================================================"
log_info "Multi-cluster Istio setup complete!"
echo "============================================================================"
echo ""
echo "Primary Cluster:  ${CTX_CLUSTER1}"
echo "Remote Cluster 1: ${CTX_CLUSTER2}"
echo "Remote Cluster 2: ${CTX_CLUSTER3}"
echo ""
echo "East-West Gateway IP: ${DISCOVERY_ADDRESS}"
echo ""
echo "To switch contexts:"
echo "  kubectl config use-context ${CTX_CLUSTER1}"
echo "  kubectl config use-context ${CTX_CLUSTER2}"
echo "  kubectl config use-context ${CTX_CLUSTER3}"
echo ""
echo "To verify the mesh:"
echo "  istioctl remote-clusters --context ${CTX_CLUSTER1}"
echo ""
