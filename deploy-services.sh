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
DEV_MODE=""  # Empty by default - will be set from env file or --dev-mode flag
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

# Source and export all variables from env file
# docker-compose --env-file uses this file for variable substitution in docker-compose.yaml
# Preserve DEV_MODE from command line flag if explicitly set, otherwise use env file value
dev_mode_flag=$DEV_MODE
set -a
source "$ENV_FILE"
set +a
# Command line flag takes precedence if explicitly set via --dev-mode
if [ "$dev_mode_flag" = "true" ]; then
    DEV_MODE="true"
fi
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

handle_docker_pull() {
    while [ -f "$DOCKER_PULL_LOCK" ]; do
        echo "Another Docker pull in progress, waiting..."
        sleep 5
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
    if [ -n "$COLLECTOR_PROFILE" ]; then
        echo "🔍 Adding collector profile: $COLLECTOR_PROFILE"
        COMPOSE_ARGS+=($COLLECTOR_PROFILE)
    else
        echo "🔍 No collector profile (COLLECTOR_PROFILE is empty or unset)"
    fi

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
            echo "🤔 Skipping local collector repository operations (NO_COLLECTOR=true)"
        else
            # Clone local collector repository for BDS DSV devnet/mainnet alpha mode
            # Note: build.sh already clones this in DEV_MODE, but deploy-services.sh may need to update the branch
            echo "🔍 Debug: BDS_DSV_DEVNET=$BDS_DSV_DEVNET, BDS_DSV_MAINNET_ALPHA=$BDS_DSV_MAINNET_ALPHA"
            if [ "$BDS_DSV_DEVNET" = "true" ] || [ "$BDS_DSV_MAINNET_ALPHA" = "true" ]; then
                if [ "$BDS_DSV_DEVNET" = "true" ]; then
                    echo "🔗 BDS DSV Devnet mode detected - ensuring local collector repository is on experimental branch..."
                else
                    echo "🔗 BDS DSV Mainnet Alpha mode detected - ensuring local collector repository is on experimental branch..."
                fi
                
                # Use experimental branch for BDS DSV (matching build.sh logic)
                DSV_BRANCH="experimental"
                LOCAL_COLLECTOR_REPO_URL="https://github.com/powerloom/snapshotter-lite-local-collector.git"
                LOCAL_COLLECTOR_DIR="./snapshotter-lite-local-collector"

                if [ ! -d "$LOCAL_COLLECTOR_DIR" ]; then
                    echo "📥 Cloning local collector repository from $LOCAL_COLLECTOR_REPO_URL"
                    git clone "$LOCAL_COLLECTOR_REPO_URL" "$LOCAL_COLLECTOR_DIR"
                    cd "$LOCAL_COLLECTOR_DIR"
                    echo "🌿 Checking out $DSV_BRANCH branch"
                    git checkout "$DSV_BRANCH"
                    cd ../
                    echo "✅ Local collector repository cloned and checked out to $DSV_BRANCH branch"
                else
                    echo "📁 Local collector directory already exists, ensuring correct branch"
                    cd "$LOCAL_COLLECTOR_DIR"
                    CURRENT_BRANCH=$(git branch --show-current)
                    if [ "$CURRENT_BRANCH" != "$DSV_BRANCH" ]; then
                        echo "🌿 Switching to $DSV_BRANCH branch"
                        git checkout "$DSV_BRANCH"
                    else
                        echo "✅ Already on $DSV_BRANCH branch"
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
# CRITICAL: Variables from env file are now exported (via set -a) and available to docker-compose
# docker-compose will use --env-file for interpolation AND shell environment for $VAR syntax
$DOCKER_COMPOSE_CMD "${COMPOSE_ARGS[@]}" up -V 