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

# Download the original Prometheus config and add federation jobs
echo "Adding federation scrape configs to Prometheus..."
curl -s https://raw.githubusercontent.com/istio/istio/release-1.28/samples/addons/prometheus.yaml > /tmp/prometheus-original.yaml

# Extract just the prometheus.yml data from the ConfigMap
ORIGINAL_CONFIG=$(grep -A 500 "prometheus.yml: |" /tmp/prometheus-original.yaml | sed -n '2,/^  [a-z]/p' | head -n -1)

# Create a new ConfigMap with federation jobs added
cat > /tmp/prometheus-federated.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  labels:
    app.kubernetes.io/component: server
    app.kubernetes.io/name: prometheus
    app.kubernetes.io/instance: prometheus
    app.kubernetes.io/version: v3.5.0
    helm.sh/chart: prometheus-27.37.0
    app.kubernetes.io/part-of: prometheus
  name: prometheus
  namespace: istio-system
data:
  allow-snippet-annotations: "false"
  alerting_rules.yml: |
    {}
  alerts: |
    {}
  prometheus.yml: |
    global:
      evaluation_interval: 1m
      scrape_interval: 15s
      scrape_timeout: 10s
    rule_files:
    - /etc/config/recording_rules.yml
    - /etc/config/alerting_rules.yml
    - /etc/config/rules
    - /etc/config/alerts
    scrape_configs:
    - job_name: prometheus
      static_configs:
      - targets:
        - localhost:9090
    # Federation jobs for multi-cluster metrics
    - job_name: 'federate-cluster2'
      honor_labels: true
      metrics_path: '/federate'
      params:
        'match[]':
          - '{job=~".+"}'
      static_configs:
        - targets: ['${CLUSTER2_PROMETHEUS_ADDRESS}:9090']
          labels:
            source_cluster: 'cluster2'
    - job_name: 'federate-cluster3'
      honor_labels: true
      metrics_path: '/federate'
      params:
        'match[]':
          - '{job=~".+"}'
      static_configs:
        - targets: ['${CLUSTER3_PROMETHEUS_ADDRESS}:9090']
          labels:
            source_cluster: 'cluster3'
    - bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      job_name: kubernetes-apiservers
      kubernetes_sd_configs:
      - role: endpoints
      relabel_configs:
      - action: keep
        regex: default;kubernetes;https
        source_labels:
        - __meta_kubernetes_namespace
        - __meta_kubernetes_service_name
        - __meta_kubernetes_endpoint_port_name
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    - bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      job_name: kubernetes-nodes
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - replacement: kubernetes.default.svc:443
        target_label: __address__
      - regex: (.+)
        replacement: /api/v1/nodes/\$1/proxy/metrics
        source_labels:
        - __meta_kubernetes_node_name
        target_label: __metrics_path__
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    - bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      job_name: kubernetes-nodes-cadvisor
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - replacement: kubernetes.default.svc:443
        target_label: __address__
      - regex: (.+)
        replacement: /api/v1/nodes/\$1/proxy/metrics/cadvisor
        source_labels:
        - __meta_kubernetes_node_name
        target_label: __metrics_path__
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    - honor_labels: true
      job_name: kubernetes-service-endpoints
      kubernetes_sd_configs:
      - role: endpoints
      relabel_configs:
      - action: keep
        regex: true
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_scrape
      - action: drop
        regex: true
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_scrape_slow
      - action: replace
        regex: (https?)
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_scheme
        target_label: __scheme__
      - action: replace
        regex: (.+)
        source_labels:
        - __meta_kubernetes_service_annotation_prometheus_io_path
        target_label: __metrics_path__
      - action: replace
        regex: (.+?)(?::\d+)?;(\d+)
        replacement: \$1:\$2
        source_labels:
        - __address__
        - __meta_kubernetes_service_annotation_prometheus_io_port
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_service_annotation_prometheus_io_param_(.+)
        replacement: __param_\$1
      - action: labelmap
        regex: __meta_kubernetes_service_label_(.+)
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_service_name
        target_label: service
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: node
    - honor_labels: true
      job_name: kubernetes-pods
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      - action: keep
        regex: true
        source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_io_scrape
      - action: drop
        regex: true
        source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_io_scrape_slow
      - action: replace
        regex: (https?)
        source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_io_scheme
        target_label: __scheme__
      - action: replace
        regex: (.+)
        source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_io_path
        target_label: __metrics_path__
      - action: replace
        regex: (\d+);(([A-Fa-f0-9]{1,4}::?){1,7}[A-Fa-f0-9]{1,4})
        replacement: '[\$2]:\$1'
        source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_io_port
        - __meta_kubernetes_pod_ip
        target_label: __address__
      - action: replace
        regex: (\d+);((([0-9]+?)(\.|$)){4})
        replacement: \$2:\$1
        source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_io_port
        - __meta_kubernetes_pod_ip
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_pod_annotation_prometheus_io_param_(.+)
        replacement: __param_\$1
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - action: replace
        source_labels:
        - __meta_kubernetes_namespace
        target_label: namespace
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_name
        target_label: pod
      - action: drop
        regex: Pending|Succeeded|Failed|Completed
        source_labels:
        - __meta_kubernetes_pod_phase
      - action: replace
        source_labels:
        - __meta_kubernetes_pod_node_name
        target_label: node
  recording_rules.yml: |
    {}
  rules: |
    {}
EOF

# Apply the federated config to cluster1
kubectl apply -f /tmp/prometheus-federated.yaml --context kind-cluster1

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

# Download the Kiali remote cluster preparation script if it doesn't exist
if [ ! -f kiali-prepare-remote-cluster.sh ]; then
  echo "Downloading kiali-prepare-remote-cluster.sh..."
  curl -sL -o kiali-prepare-remote-cluster.sh https://raw.githubusercontent.com/kiali/kiali/master/hack/istio/multicluster/kiali-prepare-remote-cluster.sh
fi
chmod +x kiali-prepare-remote-cluster.sh

# Get the actual container IPs for remote clusters (not localhost)
echo "Getting remote cluster API server addresses..."
CLUSTER2_API_SERVER="https://$(podman network inspect kind | jq -r '.[0].containers | to_entries[] | select(.value.name == "cluster2-control-plane") | .value.interfaces.eth0.subnets[] | select(.ipnet | test("^10")) | .ipnet' | cut -d'/' -f1):6443"
CLUSTER3_API_SERVER="https://$(podman network inspect kind | jq -r '.[0].containers | to_entries[] | select(.value.name == "cluster3-control-plane") | .value.interfaces.eth0.subnets[] | select(.ipnet | test("^10")) | .ipnet' | cut -d'/' -f1):6443"

echo "Cluster2 API server: ${CLUSTER2_API_SERVER}"
echo "Cluster3 API server: ${CLUSTER3_API_SERVER}"

# Prepare remote clusters BEFORE installing Kiali
echo "Preparing cluster2 as remote cluster..."
./kiali-prepare-remote-cluster.sh \
  --kiali-cluster-context kind-cluster1 \
  --remote-cluster-context kind-cluster2 \
  --remote-cluster-url "${CLUSTER2_API_SERVER}"

echo "Preparing cluster3 as remote cluster..."
./kiali-prepare-remote-cluster.sh \
  --kiali-cluster-context kind-cluster1 \
  --remote-cluster-context kind-cluster3 \
  --remote-cluster-url "${CLUSTER3_API_SERVER}"

# Install Kiali via Helm with remote cluster configuration
echo "Installing Kiali via Helm..."
helm upgrade --install --namespace istio-system \
  --set auth.strategy=anonymous \
  --set deployment.logger.log_level=debug \
  --set deployment.ingress.enabled=true \
  --set external_services.grafana.enabled=true \
  --set external_services.grafana.in_cluster_url=http://grafana.istio-system.svc.cluster.local:3000 \
  --set external_services.grafana.url=http://grafana.istio-system.svc.cluster.local:3000 \
  --set clustering.enabled=true \
  --set clustering.clusters[0].name=cluster1 \
  --set clustering.clusters[0].isKialiHome=true \
  --set clustering.clusters[1].name=kind-cluster2 \
  --set clustering.clusters[1].secretName=kiali-remote-cluster-secret-kind-cluster2 \
  --set clustering.clusters[2].name=kind-cluster3 \
  --set clustering.clusters[2].secretName=kiali-remote-cluster-secret-kind-cluster3 \
  --repo https://kiali.org/helm-charts \
  kiali-server kiali-server \
  --kube-context kind-cluster1

echo "Waiting for Kiali to be ready..."
kubectl rollout status deployment/kiali -n istio-system --context kind-cluster1 --timeout=120s

echo "Kiali setup complete!"
echo "Run 'task kiali-dashboard' to access the Kiali dashboard."
echo "Run 'istioctl dashboard grafana --context kind-cluster1' to access Grafana."


