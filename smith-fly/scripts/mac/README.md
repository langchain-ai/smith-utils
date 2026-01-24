# macOS Scripts

## minikube.sh

Smart Minikube starter script that automatically detects system resources and allocates optimal memory/CPU to Minikube.

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [Minikube](https://minikube.sigs.k8s.io/docs/start/)

### Usage

```bash
./minikube.sh up     # Start Minikube with optimal resources
./minikube.sh down   # Stop Minikube
```
