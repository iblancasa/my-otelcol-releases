#!/bin/bash

set -e

# Script configuration
SCRIPT_NAME="build-otel-multiarch.sh"
OCB_VERSION="0.133.0"
BUILD_DIR="./build"
DIST_DIR="./dist"
DEFAULT_IMAGE_NAME="opentelemetry-collector-contrib"
DEFAULT_TAG="latest"
PLATFORMS="linux/amd64,linux/arm64"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_usage() {
    cat << EOF
${SCRIPT_NAME}

Usage: $0 [OPTIONS]

Build multiarch OpenTelemetry Collector Docker images from a manifest.yaml file.

Options:
    -m, --manifest FILE     Path to manifest.yaml file (required)
    -i, --image NAME        Docker image name (default: ${DEFAULT_IMAGE_NAME})
    -t, --tag TAG           Docker image tag (default: ${DEFAULT_TAG})
    -p, --platforms LIST    Target platforms (default: ${PLATFORMS})
    -r, --registry URL      Docker registry URL (optional)
    --push                  Push image to registry after build
    --no-cache             Don't use Docker build cache
    --ocb-version VERSION   OCB version to use (default: ${OCB_VERSION})
    -h, --help             Show this help message

Examples:
    # Basic build
    $0 -m manifest.yaml

    # Build and push to registry
    $0 -m manifest.yaml -i myregistry/otelcol -t v1.0.0 --push

    # Build for specific platforms
    $0 -m manifest.yaml -p "linux/amd64,linux/arm64,linux/arm/v7"

EOF
}

# Parse command line arguments
MANIFEST_FILE=""
IMAGE_NAME="${DEFAULT_IMAGE_NAME}"
TAG="${DEFAULT_TAG}"
REGISTRY=""
PUSH_IMAGE=false
NO_CACHE=""
OCB_VERSION_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--manifest)
            MANIFEST_FILE="$2"
            shift 2
            ;;
        -i|--image)
            IMAGE_NAME="$2"
            shift 2
            ;;
        -t|--tag)
            TAG="$2"
            shift 2
            ;;
        -p|--platforms)
            PLATFORMS="$2"
            shift 2
            ;;
        -r|--registry)
            REGISTRY="$2"
            shift 2
            ;;
        --push)
            PUSH_IMAGE=true
            shift
            ;;
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --ocb-version)
            OCB_VERSION_OVERRIDE="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

if [[ -n "${OCB_VERSION_OVERRIDE}" ]]; then
    OCB_VERSION="${OCB_VERSION_OVERRIDE}"
fi

if [[ -z "${MANIFEST_FILE}" ]]; then
    print_error "Manifest file is required. Use -m or --manifest option."
    show_usage
    exit 1
fi

if [[ ! -f "${MANIFEST_FILE}" ]]; then
    print_error "Manifest file '${MANIFEST_FILE}' does not exist."
    exit 1
fi

FULL_IMAGE_NAME="${IMAGE_NAME}"
if [[ -n "${REGISTRY}" ]]; then
    FULL_IMAGE_NAME="${REGISTRY}/${IMAGE_NAME}"
fi


print_info "Configuration:"
echo "  Manifest: ${MANIFEST_FILE}"
echo "  Image: ${FULL_IMAGE_NAME}:${TAG}"
echo "  Platforms: ${PLATFORMS}"
echo "  OCB Version: ${OCB_VERSION}"
echo "  Push: ${PUSH_IMAGE}"
echo ""

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

install_ocb() {
    local ocb_path="./ocb"

    if [[ -f "${ocb_path}" ]]; then
        local current_version
        current_version=$(${ocb_path} version 2>/dev/null | grep -o "v[0-9]\+\.[0-9]\+\.[0-9]\+" | sed 's/v//' || echo "unknown")
        if [[ "${current_version}" == "${OCB_VERSION}" ]]; then
            print_info "OCB ${OCB_VERSION} already installed"
            return 0
        fi
    fi

    print_info "Installing OCB v${OCB_VERSION}..."

    if ! command_exists go; then
        print_error "Go is required but not installed. Please install Go first."
        exit 1
    fi

    CGO_ENABLED=0 go install -trimpath -ldflags="-s -w" go.opentelemetry.io/collector/cmd/builder@v${OCB_VERSION}
    cp "$(go env GOPATH)/bin/builder" "${ocb_path}"

    if [[ -f "${ocb_path}" ]]; then
        print_success "OCB installed successfully"
    else
        print_error "Failed to install OCB"
        exit 1
    fi
}

setup_docker_buildx() {
    print_info "Setting up Docker buildx..."

    if ! command_exists docker; then
        print_error "Docker is required but not installed."
        exit 1
    fi

    local builder_name="otel-multiarch-builder"

    if docker buildx ls | grep -q "${builder_name}"; then
        print_info "Using existing buildx builder: ${builder_name}"
        docker buildx use "${builder_name}"
    else
        print_info "Creating new buildx builder: ${builder_name}"
        docker buildx create --name "${builder_name}" --use --platform "${PLATFORMS}"
    fi

    print_info "Bootstrapping buildx builder..."
    docker buildx inspect --bootstrap
}

# Function to build collector binaries for multiple architectures
build_collector() {
    print_info "Building OpenTelemetry Collector binaries for multiple architectures..."

    rm -rf "${BUILD_DIR}" "${DIST_DIR}"
    mkdir -p "${BUILD_DIR}" "${DIST_DIR}"

    cp "${MANIFEST_FILE}" "${BUILD_DIR}/manifest.yaml"

    local ocb_path="../ocb"
    cd "${BUILD_DIR}"

    # Parse platforms and build for each
    IFS=',' read -ra PLATFORM_ARRAY <<< "${PLATFORMS}"
    for platform in "${PLATFORM_ARRAY[@]}"; do
        local goos=$(echo "${platform}" | cut -d'/' -f1)
        local goarch=$(echo "${platform}" | cut -d'/' -f2)

        if [[ "${goos}" != "linux" ]]; then
            continue
        fi

        print_info "Building for ${goos}/${goarch}..."

        export GOOS="${goos}"
        export GOARCH="${goarch}"
        export CGO_ENABLED=0

        local arch_dist="../${DIST_DIR}/${goarch}"
        mkdir -p "${arch_dist}"

        "${ocb_path}" --config manifest.yaml --output-path="${arch_dist}" --ldflags="-s -w -extldflags '-static'"

        local binary_file
        if [[ "$(uname)" == "Darwin" ]]; then
            binary_file=$(find "${arch_dist}" -name "otelcol*" -type f -perm +111 | head -1)
        else
            binary_file=$(find "${arch_dist}" -name "otelcol*" -type f -executable | head -1)
        fi

        if [[ -n "${binary_file}" && -f "${binary_file}" ]]; then
            print_success "Collector binary built successfully for ${goarch}: $(basename "${binary_file}")"

            if [[ "$(basename "${binary_file}")" != "otelcol-contrib" ]]; then
                mv "${binary_file}" "${arch_dist}/otelcol-contrib"
                print_info "Binary renamed to: otelcol-contrib"
            else
                print_info "Binary already named: otelcol-contrib"
            fi
        else
            print_error "Failed to build collector binary for ${goarch}"
            exit 1
        fi
    done

    unset GOOS GOARCH CGO_ENABLED

    cd ..
}

# Function to build Docker image
build_docker_image() {
    print_info "Building multiarch Docker image..."

    cp Dockerfile "${BUILD_DIR}/Dockerfile"
    cp config.yaml "${BUILD_DIR}/config.yaml"

    cp -r "${DIST_DIR}" "${BUILD_DIR}/"

    local build_cmd="docker buildx build ${NO_CACHE} --platform ${PLATFORMS}"

    if [[ "${PUSH_IMAGE}" == true ]]; then
        build_cmd="${build_cmd} --push"
    else
        print_warning "Multiarch builds cannot be loaded locally. Building without --load."
        print_info "To use the image locally, either:"
        print_info "1. Use --push to push to registry, or"
        print_info "2. Build for single platform: -p linux/amd64"
    fi

    build_cmd="${build_cmd} -t ${FULL_IMAGE_NAME}:${TAG} ${BUILD_DIR}"

    print_info "Running: ${build_cmd}"
    eval "${build_cmd}"

    if eval "${build_cmd}"; then
        print_success "Docker image built successfully"
        if [[ "${PUSH_IMAGE}" == true ]]; then
            print_success "Image pushed to registry: ${FULL_IMAGE_NAME}:${TAG}"
        else
            print_success "Image available locally: ${FULL_IMAGE_NAME}:${TAG}"
        fi
    else
        print_error "Failed to build Docker image"
        exit 1
    fi
}

main() {
    print_info "Starting OpenTelemetry Collector multiarch build process..."

    install_ocb
    setup_docker_buildx

    build_collector
    build_docker_image

    print_success "Build process completed successfully!"
    echo ""
    print_info "Your multiarch OpenTelemetry Collector image is ready:"
    echo "  Image: ${FULL_IMAGE_NAME}:${TAG}"
    echo "  Platforms: ${PLATFORMS}"

    if [[ "${PUSH_IMAGE}" == false ]]; then
        echo ""
        print_info "To run the collector:"
        echo "  docker run --rm -p 4317:4317 -p 4318:4318 ${FULL_IMAGE_NAME}:${TAG}"
        echo ""
        print_info "To push to registry later:"
        echo "  docker buildx build --platform ${PLATFORMS} --push -t ${FULL_IMAGE_NAME}:${TAG} ."
    fi
}

main "$@"