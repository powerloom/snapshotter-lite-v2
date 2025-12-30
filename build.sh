#!/bin/bash

# Parse arguments to check for dev mode and other flags
DEV_MODE=false
DSV_DEVNET=false
SETUP_ARGS=""

for arg in "$@"; do
    case $arg in
        --dev-mode)
            DEV_MODE=true
            ;;
        --bds-dsv-devnet)
            DEV_MODE=true
            DSV_DEVNET=true
            ;;
        *)
            SETUP_ARGS="$SETUP_ARGS $arg"
            ;;
    esac
done

# Build the setup container first
echo "🏗️ Building setup container..."
docker build -f Dockerfile.setup -t snapshotter-lite-setup:latest .

# Create a temporary file to capture the env file path from setup
SETUP_RESULT_DIR=$(mktemp -d "$(pwd)/setup_result.XXXXXX")
SETUP_RESULT_FILE="$SETUP_RESULT_DIR/setup_result"

# Run setup container directly
echo "🔧 Running setup container to configure environment..."
if [ "$DSV_DEVNET" = "true" ]; then
    echo "🚀 BDS DSV Devnet mode enabled"
    SETUP_ARGS="$SETUP_ARGS --bds-dsv-devnet"
fi

docker run --rm \
    -v "$(pwd):/app" \
    -v "$SETUP_RESULT_DIR:/tmp/setup_result_dir" \
    -w /app \
    snapshotter-lite-setup:latest \
    bash -c "./configure-environment.sh $SETUP_ARGS --docker-mode --result-file /tmp/setup_result_dir/setup_result"

# Remove the setup container image (non-fatal - may fail if other containers are using it)
# This is safe to ignore in multi-slot deployments where multiple instances may share the image
if ! docker rmi snapshotter-lite-setup:latest 2>/dev/null; then
    echo "ℹ️  Setup container image still in use by other containers - skipping removal (this is safe)"
fi

# Check if setup was successful by reading the result file
if [ -f "$SETUP_RESULT_FILE" ] && [ -s "$SETUP_RESULT_FILE" ]; then
    SELECTED_ENV_FILE=$(cat "$SETUP_RESULT_FILE")
    rm -rf "$SETUP_RESULT_DIR"
    
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
    rm -rf "$SETUP_RESULT_DIR"
    exit 1
fi

# Source the environment file, preserving the command-line DEV_MODE setting
dev_mode_from_flag=$DEV_MODE
source "$SELECTED_ENV_FILE"
DEV_MODE=$dev_mode_from_flag

# Ensure FULL_NAMESPACE is available
if [ -z "$FULL_NAMESPACE" ]; then
    echo "❌ FULL_NAMESPACE not found in $SELECTED_ENV_FILE"
    exit 1
fi

# Export variables so they're available to child scripts
export FULL_NAMESPACE
export NO_COLLECTOR

# Generate P2P private key if not present (runs on host system with Docker access)
if ! grep -q "^[[:space:]]*LOCAL_COLLECTOR_PRIVATE_KEY=" "$SELECTED_ENV_FILE"; then
    echo ""
    echo "🔑 Generating P2P private key on host system..."

    # Create temporary file for key generator output
    TEMP_KEYGEN_OUTPUT=$(mktemp)
    echo "   Using temporary file: $TEMP_KEYGEN_OUTPUT"

    # Check if keygen directory exists
    if [ ! -d "keygen" ]; then
        echo "   ❌ Keygen directory not found at $(pwd)/keygen"
        echo "   Current directory: $(pwd)"
        rm -f "$TEMP_KEYGEN_OUTPUT"
        exit 1
    fi

    # Use golang:1.24-alpine (matches go.mod version)
    GO_IMAGE="golang:1.24-alpine"
    echo "   Using Go image: $GO_IMAGE"
    
    # Pre-pull the image to avoid hanging during run if image needs to be downloaded
    echo "   Ensuring Go image is available..."
    if ! docker image inspect "$GO_IMAGE" >/dev/null 2>&1; then
        echo "   Pulling Go image (this may take a moment)..."
        docker pull "$GO_IMAGE" || {
            echo "   ❌ Failed to pull Go image"
            rm -f "$TEMP_KEYGEN_OUTPUT"
            exit 1
        }
    fi
    
    # Run key generator in Docker and capture output
    # Note: go mod download may take time on first run, but should complete
    echo "   Running key generator (downloading dependencies if needed)..."
    echo "   (This may take 30-60 seconds on first run while downloading Go modules)"
    if docker run --rm \
        -v "$(pwd)/keygen:/app" \
        -w /app \
        "$GO_IMAGE" \
        sh -c "go mod download && go run generate_key.go" > "$TEMP_KEYGEN_OUTPUT" 2>&1; then
        echo "   ✅ Key generator container executed successfully"
    else
        EXIT_CODE=$?
        echo "   ❌ Key generator container failed (exit code: $EXIT_CODE)"
        echo "   Output:"
        cat "$TEMP_KEYGEN_OUTPUT" 2>/dev/null || echo "   No output file found"
        echo ""
        echo "   🔧 Troubleshooting:"
        echo "   - Check if Docker is running: docker ps"
        echo "   - Check if Go image exists: docker pull $GO_IMAGE"
        echo "   - Verify keygen directory: ls -la $(pwd)/keygen"
        echo "   - Check network connectivity (go mod download requires internet)"
        rm -f "$TEMP_KEYGEN_OUTPUT"
        exit 1
    fi

    # Extract the key from output - try multiple methods
    echo "   🔍 Extracting private key from output..."

    # Method 1: Look for the exact expected format
    PRIVATE_KEY=$(grep "Generated Private Key (hex):" "$TEMP_KEYGEN_OUTPUT" | awk '{print $5}' | head -1)

    # Method 2: Fallback to grep with sed if Method 1 fails
    if [ -z "$PRIVATE_KEY" ] || [ ${#PRIVATE_KEY} -ne 128 ]; then
        PRIVATE_KEY=$(grep "Generated Private Key (hex):" "$TEMP_KEYGEN_OUTPUT" | sed 's/.*: //' | awk '{print $1}' | head -1)
    fi

    # Method 3: Final fallback - extract any 128-character hex string
    if [ -z "$PRIVATE_KEY" ] || [ ${#PRIVATE_KEY} -ne 128 ]; then
        PRIVATE_KEY=$(grep -o "[a-fA-F0-9]\{128\}" "$TEMP_KEYGEN_OUTPUT" | head -1)
    fi

    # Validate the extracted key
    if [ -n "$PRIVATE_KEY" ] && [ ${#PRIVATE_KEY} -eq 128 ] && [[ "$PRIVATE_KEY" =~ ^[a-fA-F0-9]{128}$ ]]; then
        echo "LOCAL_COLLECTOR_PRIVATE_KEY=$PRIVATE_KEY" >> "$SELECTED_ENV_FILE"
        echo "✅ P2P private key generated and added to environment file"
        echo "   Key: ${PRIVATE_KEY:0:8}...${PRIVATE_KEY: -8}"
    else
        echo "❌ Failed to extract valid P2P key from generator output"
        echo "   Expected: 128-character hex string"
        echo "   Got: ${#PRIVATE_KEY} characters: '${PRIVATE_KEY:0:16}...'"
        echo "   Full output:"
        cat "$TEMP_KEYGEN_OUTPUT" 2>/dev/null || echo "   No output file found"
        echo ""
        echo "   🔧 Debugging - Checking generator output patterns:"
        grep -i "private\|key\|generated\|error" "$TEMP_KEYGEN_OUTPUT" 2>/dev/null || echo "   No matching patterns found"
        rm -f "$TEMP_KEYGEN_OUTPUT"
        exit 1
    fi
    rm -f "$TEMP_KEYGEN_OUTPUT"
else
    echo "✅ P2P private key already exists in environment file"
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
else
    # remove the local collector repository if it exists
    if [ -d "snapshotter-lite-local-collector" ]; then
        rm -rf snapshotter-lite-local-collector
    fi
    # clone the local collector repository
    git clone https://github.com/powerloom/snapshotter-lite-local-collector.git snapshotter-lite-local-collector/
    cd snapshotter-lite-local-collector/
    # Use feat/dsv-p2p-autorelay-central-seq-off branch for BDS DSV devnet, otherwise dockerify
    if [ "$DSV_DEVNET" = "true" ]; then
        git checkout feat/dsv-p2p-autorelay-central-seq-off
        echo "✅ Local collector repository cloned and checked out to feat/dsv-p2p-autorelay-central-seq-off branch (BDS DSV devnet)"
    else
        git checkout dockerify
        echo "✅ Local collector repository cloned and checked out to dockerify branch"
    fi
    cd ../
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
    DEPLOY_ARGS="--env-file \"$SELECTED_ENV_FILE\" --project-name \"$PROJECT_NAME_LOWER\" --collector-profile \"$COMPOSE_PROFILES\" --dev-mode"
    if [ "$DSV_DEVNET" == "true" ]; then
        DEPLOY_ARGS="$DEPLOY_ARGS --bds-dsv-devnet"
    fi
    eval "./deploy-services.sh $DEPLOY_ARGS"
else
    ./deploy-services.sh --env-file "$SELECTED_ENV_FILE" \
        --project-name "$PROJECT_NAME_LOWER" \
        --collector-profile "$COMPOSE_PROFILES" \
        --image-tag "$IMAGE_TAG"
fi

