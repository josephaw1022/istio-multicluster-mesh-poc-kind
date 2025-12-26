#!/bin/bash

set -e

echo "Installing Prometheus and Kiali for Istio 1.28..."

# Pull and load images into kind cluster1
echo "Pulling and loading images into kind cluster1..."

docker image inspect ghcr.io/prometheus-operator/prometheus-config-reloader:v0.85.0 > /dev/null 2>&1 || docker pull ghcr.io/prometheus-operator/prometheus-config-reloader:v0.85.0
docker image inspect docker.io/prom/prometheus:v3.5.0 > /dev/null 2>&1 || docker pull docker.io/prom/prometheus:v3.5.0
docker image inspect quay.io/kiali/kiali:v2.20.0 > /dev/null 2>&1 || docker pull quay.io/kiali/kiali:v2.20.0
docker image inspect docker.io/grafana/grafana:12.0.1 > /dev/null 2>&1 || docker pull docker.io/grafana/grafana:12.0.1

kind load docker-image ghcr.io/prometheus-operator/prometheus-config-reloader:v0.85.0 --name cluster1
kind load docker-image docker.io/prom/prometheus:v3.5.0 --name cluster1
kind load docker-image quay.io/kiali/kiali:v2.20.0 --name cluster1
kind load docker-image docker.io/grafana/grafana:12.0.1 --name cluster1

# Load Prometheus images into remote clusters
echo "Loading Prometheus images into remote clusters..."
kind load docker-image ghcr.io/prometheus-operator/prometheus-config-reloader:v0.85.0 --name cluster2
kind load docker-image docker.io/prom/prometheus:v3.5.0 --name cluster2
kind load docker-image ghcr.io/prometheus-operator/prometheus-config-reloader:v0.85.0 --name cluster3
kind load docker-image docker.io/prom/prometheus:v3.5.0 --name cluster3

# Apply Prometheus to all clusters
echo "Applying Prometheus to all clusters..."
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.28/samples/addons/prometheus.yaml --context kind-cluster1
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.28/samples/addons/prometheus.yaml --context kind-cluster2
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.28/samples/addons/prometheus.yaml --context kind-cluster3

# Wait for Prometheus to be ready on all clusters
echo "Waiting for Prometheus to be ready on all clusters..."
kubectl rollout status deployment/prometheus -n istio-system --context kind-cluster1 --timeout=120s
kubectl rollout status deployment/prometheus -n istio-system --context kind-cluster2 --timeout=120s
kubectl rollout status deployment/prometheus -n istio-system --context kind-cluster3 --timeout=120s

# ============================================================================
# Prometheus Federation - cluster1 will scrape metrics from cluster2 and cluster3
# ============================================================================
echo "Configuring Prometheus federation..."

# Expose Prometheus on cluster2 and cluster3 via LoadBalancer
echo "Exposing Prometheus on remote clusters via LoadBalancer..."
kubectl patch svc prometheus -n istio-system --context kind-cluster2 -p '{"spec": {"type": "LoadBalancer"}}'
kubectl patch svc prometheus -n istio-system --context kind-cluster3 -p '{"spec": {"type": "LoadBalancer"}}'

# Wait for LoadBalancer IPs to be assigned
echo "Waiting for Prometheus LoadBalancer IPs..."
kubectl wait --context kind-cluster2 -n istio-system --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' svc/prometheus --timeout=120s
kubectl wait --context kind-cluster3 -n istio-system --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' svc/prometheus --timeout=120s

# Get the LoadBalancer IPs
CLUSTER2_PROMETHEUS_ADDRESS=$(kubectl --context=kind-cluster2 -n istio-system get svc prometheus -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
CLUSTER3_PROMETHEUS_ADDRESS=$(kubectl --context=kind-cluster3 -n istio-system get svc prometheus -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "Cluster2 Prometheus address: ${CLUSTER2_PROMETHEUS_ADDRESS}"
echo "Cluster3 Prometheus address: ${CLUSTER3_PROMETHEUS_ADDRESS}"

# Create federated Prometheus config for cluster1
echo "Creating federated Prometheus configuration..."
cat <<EOF | kubectl apply -f - --context kind-cluster1
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-federation
  namespace: istio-system
data:
  prometheus-federation.yml: |
    - job_name: 'prometheus-cluster2'
      honor_labels: true
      metrics_path: '/federate'
      params:
        'match[]':
          - '{job=~".+"}'
      static_configs:
        - targets:
          - '${CLUSTER2_PROMETHEUS_ADDRESS}:9090'
          labels:
            cluster: 'cluster2'
    - job_name: 'prometheus-cluster3'
      honor_labels: true
      metrics_path: '/federate'
      params:
        'match[]':
          - '{job=~".+"}'
      static_configs:
        - targets:
          - '${CLUSTER3_PROMETHEUS_ADDRESS}:9090'
          labels:
            cluster: 'cluster3'
EOF

# Patch the Prometheus deployment to include the federation config
echo "Patching Prometheus to include federation scrape configs..."
kubectl patch deployment prometheus -n istio-system --context kind-cluster1 --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "prometheus-federation",
      "configMap": {
        "name": "prometheus-federation"
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "prometheus-federation",
      "mountPath": "/etc/prometheus-federation"
    }
  }
]'

# Update Prometheus config to include federation
kubectl get configmap prometheus -n istio-system --context kind-cluster1 -o yaml > /tmp/prometheus-cm.yaml
if ! grep -q "prometheus-cluster2" /tmp/prometheus-cm.yaml; then
  echo "Adding federation scrape configs to Prometheus..."
  kubectl patch configmap prometheus -n istio-system --context kind-cluster1 --type='json' -p="[
    {
      \"op\": \"add\",
      \"path\": \"/data/prometheus.yml\",
      \"value\": \"$(kubectl get configmap prometheus -n istio-system --context kind-cluster1 -o jsonpath='{.data.prometheus\.yml}' | sed '/^scrape_configs:/a\\
  - job_name: prometheus-cluster2\\
    honor_labels: true\\
    metrics_path: /federate\\
    params:\\
      match[]:\\
        - {job=~\".+\"}\\
    static_configs:\\
      - targets:\\
          - ${CLUSTER2_PROMETHEUS_ADDRESS}:9090\\
        labels:\\
          cluster: cluster2\\
  - job_name: prometheus-cluster3\\
    honor_labels: true\\
    metrics_path: /federate\\
    params:\\
      match[]:\\
        - {job=~\".+\"}\\
    static_configs:\\
      - targets:\\
          - ${CLUSTER3_PROMETHEUS_ADDRESS}:9090\\
        labels:\\
          cluster: cluster3' | sed 's/"/\\"/g' | tr '\n' '\\n')\"
    }
  ]" 2>/dev/null || echo "Federation config may already exist or requires manual update"
fi

# Restart Prometheus to pick up the new config
echo "Restarting Prometheus to apply federation config..."
kubectl rollout restart deployment/prometheus -n istio-system --context kind-cluster1
kubectl rollout status deployment/prometheus -n istio-system --context kind-cluster1 --timeout=120s

# ============================================================================
# Grafana Installation
# ============================================================================
echo "Installing Grafana..."
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.28/samples/addons/grafana.yaml --context kind-cluster1

echo "Waiting for Grafana to be ready..."
kubectl rollout status deployment/grafana -n istio-system --context kind-cluster1 --timeout=120s

# Configure Kiali for multicluster (must be done before installing Kiali)
echo "Configuring Kiali for multicluster..."
chmod +x kiali-prepare-remote-cluster.sh

# Get the actual container IPs for remote clusters (not localhost)
echo "Getting remote cluster API server addresses..."
CLUSTER2_API_SERVER="https://$(podman network inspect kind | jq -r '.[0].containers | to_entries[] | select(.value.name == "cluster2-control-plane") | .value.interfaces.eth0.subnets[] | select(.ipnet | test("^10")) | .ipnet' | cut -d'/' -f1):6443"
CLUSTER3_API_SERVER="https://$(podman network inspect kind | jq -r '.[0].containers | to_entries[] | select(.value.name == "cluster3-control-plane") | .value.interfaces.eth0.subnets[] | select(.ipnet | test("^10")) | .ipnet' | cut -d'/' -f1):6443"

echo "Cluster2 API server: ${CLUSTER2_API_SERVER}"
echo "Cluster3 API server: ${CLUSTER3_API_SERVER}"

# Install Kiali via Helm
echo "Installing Kiali via Helm..."
helm upgrade --install --namespace istio-system \
  --set auth.strategy=anonymous \
  --set deployment.logger.log_level=debug \
  --set deployment.ingress.enabled=true \
  --set external_services.grafana.enabled=true \
  --set external_services.grafana.in_cluster_url=http://grafana.istio-system.svc.cluster.local:3000 \
  --set external_services.grafana.url=http://grafana.istio-system.svc.cluster.local:3000 \
  --repo https://kiali.org/helm-charts \
  kiali-server kiali-server \
  --kube-context kind-cluster1


echo "Adding cluster2 as remote cluster to Kiali..."
./kiali-prepare-remote-cluster.sh \
  --kiali-cluster-context kind-cluster1 \
  --remote-cluster-context kind-cluster2 \
  --remote-cluster-url "${CLUSTER2_API_SERVER}"

echo "Adding cluster3 as remote cluster to Kiali..."
./kiali-prepare-remote-cluster.sh \
  --kiali-cluster-context kind-cluster1 \
  --remote-cluster-context kind-cluster3 \
  --remote-cluster-url "${CLUSTER3_API_SERVER}"


echo "Waiting for Kiali to be ready..."
kubectl rollout status deployment/kiali -n istio-system --context kind-cluster1 --timeout=120s

echo "Kiali setup complete!"
echo "Run 'task kiali-dashboard' to access the Kiali dashboard."
echo "Run 'istioctl dashboard grafana --context kind-cluster1' to access Grafana."


