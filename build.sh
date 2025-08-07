#!/bin/bash

# Parse arguments to check for dev mode and other flags
DEV_MODE=false
SETUP_ARGS=""

for arg in "$@"; do
    case $arg in
        --dev-mode)
            DEV_MODE=true
            ;;
        *)
            SETUP_ARGS="$SETUP_ARGS $arg"
            ;;
    esac
done

# Build the setup container first
echo "🏗️ Building setup container..."
docker build -f Dockerfile.setup -t snapshotter-lite-setup:latest .

# Determine docker compose command and files
if command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker-compose"
else
    DOCKER_COMPOSE_CMD="docker compose"
fi

if [ "$DEV_MODE" = "true" ]; then
    COMPOSE_FILE="docker-compose-dev.yaml"
else
    COMPOSE_FILE="docker-compose.yaml"
fi

# Export environment variables for docker-compose
export DEVNET_MODE=${DEVNET_MODE:-false}
export DATA_MARKET_CONTRACT_NUMBER=${DATA_MARKET_CONTRACT_NUMBER:-}
export SKIP_CREDENTIAL_UPDATE=${SKIP_CREDENTIAL_UPDATE:-false}
export NO_COLLECTOR=${NO_COLLECTOR:-false}
export OVERRIDE_DEFAULTS_SCRIPT_FLAG=${OVERRIDE_DEFAULTS_SCRIPT_FLAG:-false}

# Create a temporary file to capture the env file path from setup
SETUP_RESULT_FILE=$(mktemp)

# Run setup container to configure environment
echo "🔧 Running setup container to configure environment..."
$DOCKER_COMPOSE_CMD -f $COMPOSE_FILE --profile setup run --rm \
    -v "$SETUP_RESULT_FILE:/tmp/setup_result" \
    snapshotter-lite-setup bash -c "./configure-environment.sh --docker-mode $SETUP_ARGS"

# Check if setup was successful by reading the result file
if [ -f "$SETUP_RESULT_FILE" ] && [ -s "$SETUP_RESULT_FILE" ]; then
    SELECTED_ENV_FILE=$(cat "$SETUP_RESULT_FILE")
    rm -f "$SETUP_RESULT_FILE"
    
    if [ -n "$SELECTED_ENV_FILE" ] && [ -f "$SELECTED_ENV_FILE" ]; then
        echo "ℹ️ Setup container configured: $SELECTED_ENV_FILE"
    else
        echo "❌ Setup container failed to report a valid env file."
        echo "   Reported: '$SELECTED_ENV_FILE'"
        echo "   This indicates a problem with the configuration process."
        exit 1
    fi
else
    echo "❌ Setup container did not complete successfully or failed to report results."
    rm -f "$SETUP_RESULT_FILE"
    exit 1
fi

# Source the environment file to get variables
source "$SELECTED_ENV_FILE"

# Ensure FULL_NAMESPACE is available
if [ -z "$FULL_NAMESPACE" ]; then
    echo "❌ FULL_NAMESPACE not found in $SELECTED_ENV_FILE"
    exit 1
fi

if [ "$DEV_MODE" != "true" ]; then
    # Set image tag based on git branch
    GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ "$GIT_BRANCH" = "dockerify" ]; then
        export IMAGE_TAG="dockerify"
    elif [ "$GIT_BRANCH" = "experimental" ]; then
        export IMAGE_TAG="experimental"
    else
        export IMAGE_TAG="latest"
    fi
    if [ -z "$LOCAL_COLLECTOR_IMAGE_TAG" ]; then
        if [ "$GIT_BRANCH" = "experimental" ] || [ "$GIT_BRANCH" = "dockerify" ]; then
            # TODO: Change this to use 'experimental' once we have a proper experimental image for local collector
            export LOCAL_COLLECTOR_IMAGE_TAG="dockerify"
        else
            export LOCAL_COLLECTOR_IMAGE_TAG=${IMAGE_TAG}
        fi
        echo "🔔 LOCAL_COLLECTOR_IMAGE_TAG not found in .env, setting to default value ${LOCAL_COLLECTOR_IMAGE_TAG}"
    else
        echo "🔔 LOCAL_COLLECTOR_IMAGE_TAG found in .env, using value ${LOCAL_COLLECTOR_IMAGE_TAG}"
    fi 
    echo "🏗️ Running snapshotter-lite-v2 node Docker image with tag ${IMAGE_TAG}"
    echo "🏗️ Running snapshotter-lite-local-collector Docker image with tag ${LOCAL_COLLECTOR_IMAGE_TAG}"
fi

# Run collector test
if [ "$NO_COLLECTOR" = "true" ]; then
    echo "🤔 Skipping collector check (--no-collector flag)"
    COLLECTOR_PROFILE_STRING=""
else
    ./collector_test.sh --env-file ".env-${FULL_NAMESPACE}"
    test_result=$?
    if [ $test_result -eq 101 ]; then
        echo "ℹ️  Starting new collector instance"
        COLLECTOR_PROFILE_STRING="--profile local-collector"
    elif [ $test_result -eq 100 ]; then
        echo "✅ Using existing collector instance"
        COLLECTOR_PROFILE_STRING=""
    else
        echo "❌ Collector check failed (exit code: $test_result)"
        exit 1
    fi
fi

# Create lowercase versions of namespace variables
PROJECT_NAME="snapshotter-lite-v2-${SLOT_ID}-${FULL_NAMESPACE}"
PROJECT_NAME_LOWER=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]')
FULL_NAMESPACE_LOWER=$(echo "$FULL_NAMESPACE" | tr '[:upper:]' '[:lower:]')

# Export the lowercase version for docker-compose
export FULL_NAMESPACE_LOWER

COMPOSE_PROFILES="${COLLECTOR_PROFILE_STRING}"

# Modify the deploy-services call to use the profiles (setup already ran)
if [ "$DEV_MODE" == "true" ]; then
    ./deploy-services.sh --env-file "$SELECTED_ENV_FILE" \
        --project-name "$PROJECT_NAME_LOWER" \
        --collector-profile "$COMPOSE_PROFILES" \
        --dev-mode
else
    ./deploy-services.sh --env-file "$SELECTED_ENV_FILE" \
        --project-name "$PROJECT_NAME_LOWER" \
        --collector-profile "$COMPOSE_PROFILES" \
        --image-tag "$IMAGE_TAG"
fi

