# Contributing to Istio Multi-Cluster Setup

Thank you for your interest in contributing! This document provides guidelines and information for contributors.

## How to Contribute

### Reporting Bugs

If you find a bug, please open an issue with:
- A clear, descriptive title
- Steps to reproduce the problem
- Expected behavior vs actual behavior
- Your environment (OS, Kind version, Istio version, etc.)

### Suggesting Features

Feature requests are welcome! Please open an issue with:
- A clear description of the feature
- The use case / problem it solves
- Any implementation ideas you have

### Pull Requests

1. **Fork** the repository
2. **Clone** your fork locally
3. **Create a branch** for your changes:
   ```bash
   git checkout -b feature/your-feature-name
   ```
4. **Make your changes** and test them
5. **Commit** with clear, descriptive messages:
   ```bash
   git commit -m "Add feature: description of changes"
   ```
6. **Push** to your fork:
   ```bash
   git push origin feature/your-feature-name
   ```
7. **Open a Pull Request** against the `main` branch

## Development Setup

1. Ensure you have the prerequisites installed:
   - Kind
   - kubectl
   - Podman or Docker
   - Task (taskfile.dev)

2. Clone the repository:
   ```bash
   git clone https://github.com/YOUR_USERNAME/istioctl-spike.git
   cd istioctl-spike
   ```

3. Test your changes:
   ```bash
   task clean
   task setup
   task verify-mesh
   ```

## Code Style

- **Shell scripts**: Follow [Google's Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- Use meaningful variable names
- Add comments for complex logic
- Include error handling with `set -euo pipefail`

## Testing

Before submitting a PR, please ensure:

1. The setup script runs successfully: `task setup`
2. The mesh verification passes: `task verify-mesh`
3. The demo deployment works: `task deploy-nginx`
4. Clean up works properly: `task clean`

## Questions?

Feel free to open an issue for any questions about contributing!
