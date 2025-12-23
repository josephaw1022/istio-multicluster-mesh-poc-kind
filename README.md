# Istio Multi-Cluster Setup with Kind

A toolkit for setting up and experimenting with Istio multi-cluster mesh configurations using Kind (Kubernetes in Docker) clusters.

## Overview

This project provides scripts and configuration to quickly spin up a multi-cluster Istio service mesh environment locally. It's designed for:

- Learning and experimenting with Istio multi-cluster deployments
- Testing cross-cluster service communication
- Developing and debugging multi-cluster configurations

## Architecture

The setup creates two Kind clusters:
- **cluster1** (Primary): Runs the Istio control plane
- **cluster2** (Remote): Connects to the primary cluster's control plane

Both clusters use MetalLB for LoadBalancer support and are configured for cross-cluster communication.

## Prerequisites

- [Kind](https://kind.sigs.k8s.io/) - Kubernetes in Docker
- [kubectl](https://kubernetes.io/docs/tasks/tools/) - Kubernetes CLI
- [Podman](https://podman.io/) or Docker - Container runtime
- [Task](https://taskfile.dev/) - Task runner (optional, but recommended)
- [istioctl](https://istio.io/latest/docs/setup/getting-started/#download) - Istio CLI

## Quick Start

1. **Clone the repository**
   ```bash
   git clone https://github.com/YOUR_USERNAME/istioctl-spike.git
   cd istioctl-spike
   ```

2. **Install istioctl** (if not already installed)
   ```bash
   task install-istioctl
   ```

3. **Set up the multi-cluster environment**
   ```bash
   task setup
   ```

4. **Verify the mesh**
   ```bash
   task verify-mesh
   ```

5. **Deploy a test application**
   ```bash
   task deploy-nginx
   ```

## Available Tasks

Run `task` or `task --list-all` to see all available commands:

| Task | Description |
|------|-------------|
| `setup` | Run the complete multi-cluster Istio setup |
| `create-cluster1` | Create the primary Kind cluster |
| `create-cluster2` | Create the remote Kind cluster |
| `delete-clusters` | Delete both Kind clusters |
| `verify-mesh` | Verify the multi-cluster mesh connectivity |
| `deploy-nginx` | Deploy nginx demo and test cross-cluster connectivity |
| `clean-nginx` | Clean up nginx demo deployment |
| `clean` | Clean up all clusters and resources |
| `install-istioctl` | Install istioctl using the official installer |
| `uninstall-istioctl` | Remove istioctl and related files |

## Project Structure

```
.
├── setup-clusters.sh      # Main setup script for multi-cluster Istio
├── deploy-nginx.sh        # Demo deployment for testing cross-cluster communication
├── kind-config.yaml       # Kind cluster configuration for cluster1 (primary)
├── kind-config-remote.yaml # Kind cluster configuration for cluster2 (remote)
├── Taskfile.yaml          # Task runner configuration
├── LICENSE                # MIT License
└── README.md              # This file
```

## Configuration

### Istio Version

The default Istio version is `1.28.2`. To change it, modify the `ISTIO_VERSION` variable in `setup-clusters.sh`.

### MetalLB Version

The default MetalLB version is `v0.14.9`. To change it, modify the `METALLB_VERSION` variable in `setup-clusters.sh`.

## Troubleshooting

### Clusters not communicating
Ensure MetalLB is properly configured and the clusters can reach each other:
```bash
task verify-mesh
```

### Image pull issues
The scripts pre-load images into Kind clusters to avoid pull rate limits. If you encounter issues, ensure Podman/Docker can pull the required images.

### Clean restart
To start fresh, clean up everything and re-run setup:
```bash
task clean
task setup
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Istio Documentation](https://istio.io/latest/docs/) - Multi-cluster setup guides
- [Kind](https://kind.sigs.k8s.io/) - Local Kubernetes clusters
- [MetalLB](https://metallb.universe.tf/) - Load balancer for bare metal Kubernetes
