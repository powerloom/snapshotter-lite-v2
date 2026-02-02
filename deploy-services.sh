#!/bin/bash

# Help message
show_help() {
    echo "Usage: ./deploy-services.sh [OPTIONS]"
    echo
    echo "Options:"
    echo "  -f, --env-file FILE          Use specified environment file"
    echo "  -p, --project-name NAME      Set docker compose project name"
    echo "  -c, --collector-profile STR  Set collector profile string"
    echo "  -t, --image-tag TAG         Set docker image tag"
    echo "  -d, --dev-mode              Enable dev mode"
    echo "  --bds-dsv-devnet            Enable BDS DSV devnet mode"
    echo "  --bds-dsv-mainnet-alpha     Enable BDS DSV mainnet alpha mode"
    echo "  -h, --help                  Show this help message"
    echo
    echo "Examples:"
    echo "  ./deploy-services.sh --env-file .env-pre-mainnet-AAVEV3-ETH"
    echo "  ./deploy-services.sh --project-name snapshotter-lite-v2-123-aavev3"
    echo "  ./deploy-services.sh --dev-mode"
    echo "  ./deploy-services.sh --bds-dsv-devnet"
    echo "  ./deploy-services.sh --bds-dsv-mainnet-alpha"
}

# Initialize variables
ENV_FILE=""
PROJECT_NAME=""
COLLECTOR_PROFILE=""
IMAGE_TAG="latest"
DEV_MODE="false"
BDS_DSV_DEVNET="false"
BDS_DSV_MAINNET_ALPHA="false"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        -p|--project-name)
            PROJECT_NAME="$2"
            shift 2
            ;;
        -c|--collector-profile)
            COLLECTOR_PROFILE="$2"
            shift 2
            ;;
        -t|--image-tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        -d|--dev-mode)
            DEV_MODE="true"
            shift
            ;;
        --bds-dsv-devnet)
            BDS_DSV_DEVNET="true"
            shift
            ;;
        --bds-dsv-mainnet-alpha)
            BDS_DSV_MAINNET_ALPHA="true"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate required parameters
if [ -z "$ENV_FILE" ]; then
    echo "Error: Environment file must be specified"
    exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: Environment file $ENV_FILE not found"
    exit 1
fi

# Source the environment file, preserving the DEV_MODE flag
dev_mode_from_flag=$DEV_MODE
set -a
source "$ENV_FILE"
set +a
DEV_MODE=$dev_mode_from_flag
NO_COLLECTOR=${NO_COLLECTOR:-false}

# Validate required variables
required_vars=("FULL_NAMESPACE" "SLOT_ID" "DOCKER_NETWORK_NAME")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: Required variable $var is not set"
        exit 1
    fi
done

# Cleanup and create required directories
echo "🧹 Cleaning up existing directories..."
rm -rf "./logs-${FULL_NAMESPACE_LOWER}"

echo "📁 Creating fresh directories..."
mkdir -p "./logs-${FULL_NAMESPACE_LOWER}"

# Docker pull locking mechanism
DOCKER_PULL_LOCK="/tmp/powerloom_docker_pull.lock"
LOCK_TIMEOUT=120  # 2 minutes max wait
STALE_LOCK_AGE=180  # Lock older than 3 minutes is stale

handle_docker_pull() {
    # Add random jitter (0-10 seconds) to avoid simultaneous starts
    sleep $((RANDOM % 10))
    
    local wait_time=0
    while [ -f "$DOCKER_PULL_LOCK" ]; do
        # Check if lock is stale (older than STALE_LOCK_AGE seconds)
        if [ -f "$DOCKER_PULL_LOCK" ]; then
            # Simplified stale lock check using find
            # Find returns the file if it was modified more than STALE_LOCK_AGE seconds ago
            if find "$DOCKER_PULL_LOCK" -mmin +$((STALE_LOCK_AGE / 60)) 2>/dev/null | grep -q .; then
                echo "⚠️  Removing stale lock (older than $((STALE_LOCK_AGE / 60)) minutes)"
                rm -f "$DOCKER_PULL_LOCK"
                break
            fi
        fi
        
        # Check timeout
        if [ "$wait_time" -ge "$LOCK_TIMEOUT" ]; then
            echo "❌ Timeout waiting for Docker pull lock (${LOCK_TIMEOUT}s)"
            echo "   Proceeding anyway - check for conflicts if issues occur"
            break
        fi
        
        echo "Another Docker pull in progress, waiting... (${wait_time}s/${LOCK_TIMEOUT}s)"
        sleep 5
        wait_time=$((wait_time + 5))
    done

    touch "$DOCKER_PULL_LOCK"
    trap 'rm -f $DOCKER_PULL_LOCK' EXIT

    # Determine docker compose command
    if command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        DOCKER_COMPOSE_CMD="docker compose"
    fi

    if [ "$DEV_MODE" = "true" ]; then
        # Build compose arguments
        COMPOSE_ARGS=(
            --env-file "$ENV_FILE"
            -p "${PROJECT_NAME:-snapshotter-lite-v2-${FULL_NAMESPACE}}"
            -f docker-compose-dev.yaml
        )

    else
        # Build compose arguments
        COMPOSE_ARGS=(
            --env-file "$ENV_FILE"
            -p "${PROJECT_NAME:-snapshotter-lite-v2-${FULL_NAMESPACE}}"
            -f docker-compose.yaml
        )

    fi


    # Add optional profiles
    [ -n "$IPFS_URL" ] && COMPOSE_ARGS+=("--profile" "ipfs")
    [ -n "$COLLECTOR_PROFILE" ] && COMPOSE_ARGS+=($COLLECTOR_PROFILE)

    # Set image tag and ensure network exists
    export IMAGE_TAG
    export DOCKER_NETWORK_NAME

    # check if DOCKER_NETWORK_NAME exists otherwise create it, it's a bridge network
    if ! docker network ls | grep -q "$DOCKER_NETWORK_NAME"; then
        echo "🔄 Creating docker network $DOCKER_NETWORK_NAME"
        docker network create --driver bridge "$DOCKER_NETWORK_NAME"
    fi

    if [ "$DEV_MODE" = "true" ]; then
        echo "🔧 DEV mode: building images via docker-compose..."

        # Skip collector operations if NO_COLLECTOR is set
        if [ "$NO_COLLECTOR" = "true" ]; then
            echo "🤔 Skipping local collector operations (NO_COLLECTOR=true)"
        else
            # Clone local collector repository for BDS DSV devnet/mainnet alpha mode
            if [ "$BDS_DSV_DEVNET" = "true" ] || [ "$BDS_DSV_MAINNET_ALPHA" = "true" ]; then
                if [ "$BDS_DSV_DEVNET" = "true" ]; then
                    echo "🔗 BDS DSV Devnet mode detected - cloning local collector repository..."
                else
                    echo "🔗 BDS DSV Mainnet Alpha mode detected - cloning local collector repository..."
                fi
                LOCAL_COLLECTOR_REPO_URL="https://github.com/powerloom/snapshotter-lite-local-collector.git"
                LOCAL_COLLECTOR_DIR="./snapshotter-lite-local-collector"

                if [ ! -d "$LOCAL_COLLECTOR_DIR" ]; then
                    echo "📥 Cloning local collector repository from $LOCAL_COLLECTOR_REPO_URL"
                    git clone "$LOCAL_COLLECTOR_REPO_URL" "$LOCAL_COLLECTOR_DIR"
                    cd "$LOCAL_COLLECTOR_DIR"
                    echo "🌿 Checking out experimental branch"
                    git checkout experimental
                    cd ../
                    echo "✅ Local collector repository cloned and checked out to experimental branch"
                else
                    echo "📁 Local collector directory already exists, skipping clone"
                    cd "$LOCAL_COLLECTOR_DIR"
                    CURRENT_BRANCH=$(git branch --show-current)
                    if [ "$CURRENT_BRANCH" != "experimental" ]; then
                        echo "🌿 Switching to experimental branch"
                        git checkout experimental
                    fi
                    cd ../
                fi
            else
                echo "ℹ️ BDS DSV mode not detected, skipping local collector clone"
            fi

            echo "🏗️ Building docker image for snapshotter-lite-local-collector"
            cd ./snapshotter-lite-local-collector/ && chmod +x build-docker.sh && ./build-docker.sh
            cd ../
        fi
    else
        # Execute docker compose pull
        echo "🔄 Pulling docker images"
        echo $DOCKER_COMPOSE_CMD "${COMPOSE_ARGS[@]}" pull
        $DOCKER_COMPOSE_CMD "${COMPOSE_ARGS[@]}" pull
    fi

    rm -f "$DOCKER_PULL_LOCK"
}

# Main deployment
echo "🚀 Deploying with configuration from: $ENV_FILE"
handle_docker_pull

# Deploy services
$DOCKER_COMPOSE_CMD "${COMPOSE_ARGS[@]}" up -V
