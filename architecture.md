# Istio Multi-Cluster Mesh Architecture

## Overview

This POC demonstrates a **primary-remote** Istio multi-cluster topology using Kind clusters with different networks.

```mermaid
flowchart TB
    subgraph "Host Machine"
        subgraph cluster1["cluster1 (Primary) - network1"]
            subgraph istio-system1["istio-system namespace"]
                istiod["istiod\n(Control Plane)"]
                ingress["istio-ingressgateway\n:80/:443 (NodePort 30080/30443)"]
                ew1["istio-eastwestgateway\n:15443 (cross-network)\n:15012/:15017 (control plane)"]
            end
            subgraph default1["default namespace"]
                hw1["helloworld-v1"]
                curl1["curl pod"]
            end
            metallb1["MetalLB\n10.89.1.200-220"]
        end

        subgraph cluster2["cluster2 (Remote) - network2"]
            subgraph istio-system2["istio-system namespace"]
                ew2["istio-eastwestgateway\n:15443 (cross-network)"]
            end
            subgraph default2["default namespace"]
                hw2["helloworld-v2"]
                nginx["nginx"]
                curl2["curl pod"]
            end
            metallb2["MetalLB\n10.89.1.221-240"]
        end

        kindnet["Kind Network (podman)\n10.89.0.0/24"]
    end

    %% Control Plane connections
    istiod -.->|"xDS config\nvia east-west"| ew1
    ew1 -.->|"15012/15017\ncontrol plane"| ew2
    ew2 -.->|"sidecar config"| hw2
    ew2 -.->|"sidecar config"| nginx

    %% Data Plane - Cross cluster traffic
    hw1 <-->|"15443\nmTLS via\neast-west gateways"| ew1
    ew1 <-->|"cross-network\ntraffic"| ew2
    ew2 <-->|"15443\nmTLS"| hw2

    %% Ingress traffic
    ingress -->|"route to\nservice"| hw1
    ingress -->|"via east-west"| hw2
    ingress -->|"via east-west"| nginx

    %% MetalLB provides IPs
    metallb1 -.->|"LoadBalancer IP"| ew1
    metallb2 -.->|"LoadBalancer IP"| ew2

    %% Network connectivity
    cluster1 --- kindnet
    cluster2 --- kindnet
```

## Traffic Flows

### Control Plane (cluster1 → cluster2)

```mermaid
sequenceDiagram
    participant istiod as istiod (cluster1)
    participant ew1 as east-west-gw (cluster1)
    participant ew2 as east-west-gw (cluster2)
    participant proxy as Envoy Sidecar (cluster2)

    istiod->>ew1: xDS config (15012)
    ew1->>ew2: TLS passthrough
    ew2->>proxy: Deliver config
    Note over proxy: Sidecar configured<br/>for mesh routing
```

### Data Plane (cross-cluster request)

```mermaid
sequenceDiagram
    participant curl as curl (cluster1)
    participant proxy1 as Sidecar (cluster1)
    participant ew1 as east-west-gw (cluster1)
    participant ew2 as east-west-gw (cluster2)
    participant proxy2 as Sidecar (cluster2)
    participant hw2 as helloworld-v2

    curl->>proxy1: GET /hello
    proxy1->>proxy1: Load balance (v1 local, v2 remote)
    proxy1->>ew1: mTLS to remote endpoint
    ew1->>ew2: Port 15443 (AUTO_PASSTHROUGH)
    ew2->>proxy2: Route to service
    proxy2->>hw2: Forward request
    hw2-->>curl: Response (v2)
```

### Browser Access (via Ingress Gateway)

```mermaid
sequenceDiagram
    participant browser as Browser
    participant host as Host (localhost:80)
    participant ingress as Ingress Gateway
    participant proxy as Service Sidecar
    participant app as helloworld/nginx

    browser->>host: http://helloworld.localhost/hello
    host->>ingress: NodePort 30080
    ingress->>ingress: Match Gateway + VirtualService
    ingress->>proxy: Route to service (local or via east-west)
    proxy->>app: Forward request
    app-->>browser: Response
```

## Key Components

| Component | Cluster | Purpose |
|-----------|---------|---------|
| **istiod** | cluster1 | Control plane for both clusters |
| **istio-ingressgateway** | cluster1 | North-south traffic (browser access) |
| **istio-eastwestgateway** | both | Cross-network service traffic + control plane exposure |
| **MetalLB** | both | Provides LoadBalancer IPs for gateways |
| **cross-network-gateway** | both | Gateway resource exposing `*.local` services |
| **istiod-gateway** | cluster1 | Exposes control plane ports (15012, 15017) |

## Network Configuration

- **cluster1**: `network1` - Primary cluster with istiod
- **cluster2**: `network2` - Remote cluster (different network forces east-west routing)

Because the clusters are on different networks, all cross-cluster traffic **must** flow through the east-west gateways using mTLS on port 15443.
