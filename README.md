# OpenTelemetry Collector Multiarch Builder

A script to build and package multiarch OpenTelemetry Collector Docker images from a custom manifest file.

## Features

- Builds OpenTelemetry Collector from custom manifests
- Supports multiple CPU architectures (amd64, arm64)
- Automated OCB (OpenTelemetry Collector Builder) installation
- Docker buildx setup for multiarch builds
- Configurable image registry and tags
- Clean, minimal Docker images based on scratch

## Prerequisites

- Go (for OCB installation)
- Docker with buildx support
- Git (optional, for version control)

## Usage

```bash
./build-otel-multiarch.sh [OPTIONS]
```

### Options

- `-m, --manifest FILE` : Path to manifest.yaml file (required)
- `-i, --image NAME` : Docker image name (default: otelcol-custom)
- `-t, --tag TAG` : Docker image tag (default: latest)
- `-p, --platforms LIST` : Target platforms (default: linux/amd64,linux/arm64)
- `-r, --registry URL` : Docker registry URL (optional)
- `--push` : Push image to registry after build
- `--no-cache` : Don't use Docker build cache
- `--ocb-version VERSION` : OCB version to use (default: 0.133.0)
- `-h, --help` : Show help message

### Examples

Basic build:
```bash
./build-otel-multiarch.sh -m manifest.yaml
```

Build and push to registry:
```bash
./build-otel-multiarch.sh -m manifest.yaml -i myregistry/otelcol -t v1.0.0 --push
```

Build for specific platforms:
```bash
./build-otel-multiarch.sh -m manifest.yaml -p "linux/amd64,linux/arm64,linux/arm/v7"
```

## Output

The script will:
1. Install OCB if not present
2. Set up Docker buildx for multiarch builds
3. Build the collector binary from your manifest
4. Create a minimal Docker image
5. Build for all specified architectures
6. Push to registry (if --push specified)


## Running the Collector

After building, run the collector with:

```bash
docker run --rm -p 4317:4317 -p 4318:4318 otelcol-custom:latest
```
