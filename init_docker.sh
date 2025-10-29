#!/bin/bash

handle_exit() {
    EXIT_CODE=$?
    # Random delay between 1-5 minutes, spread between 30 seconds
    MIN_DELAY=30
    MAX_DELAY=300
    ACTUAL_DELAY=$((MIN_DELAY + RANDOM % (MAX_DELAY - MIN_DELAY + 1)))
    
    echo "Container exited with code $EXIT_CODE. Restarting in $ACTUAL_DELAY seconds..."
    sleep $ACTUAL_DELAY
    exit 1
}

# Always run bootstrap
echo "🚀 Running bootstrap..."

echo "📦 Cloning fresh config repo..."
git clone --depth 1 --branch $SNAPSHOT_CONFIG_REPO_BRANCH $SNAPSHOT_CONFIG_REPO "/app/config"
cd /app/config
git fetch --depth 1 origin $SNAPSHOT_CONFIG_REPO_COMMIT
git reset --hard $SNAPSHOT_CONFIG_REPO_COMMIT
cd ..

echo "📦 Cloning fresh compute repo..."
git clone --depth 1 --branch $SNAPSHOTTER_COMPUTE_REPO_BRANCH $SNAPSHOTTER_COMPUTE_REPO "/app/computes"
cd /app/computes
git fetch --depth 1 origin $SNAPSHOTTER_COMPUTE_REPO_COMMIT
git reset --hard $SNAPSHOTTER_COMPUTE_REPO_COMMIT
cd ..

if [ $? -ne 0 ]; then
    echo "❌ Bootstrap failed"
    exit 1
fi

# Generate P2P private key if needed (for local collector integration)
generate_p2p_key() {
    echo "🔑 Checking P2P private key generation..."

    # Only generate key if LOCAL_COLLECTOR_PRIVATE_KEY is not set
    if [ -z "$LOCAL_COLLECTOR_PRIVATE_KEY" ]; then
        # Check if P2P key already exists in shared volume
        SHARED_KEY_FILE="./shared-volume/p2p_private_key"
        if [ -f "$SHARED_KEY_FILE" ]; then
            # Read and validate existing key
            VOLUME_KEY=$(cat "$SHARED_KEY_FILE" 2>/dev/null || echo "")
            if [ -n "$VOLUME_KEY" ] && [ ${#VOLUME_KEY} -eq 128 ] && [[ "$VOLUME_KEY" =~ ^[0-9a-fA-F]+$ ]]; then
                echo "✅ Found valid P2P key in shared volume"
                export LOCAL_COLLECTOR_PRIVATE_KEY="$VOLUME_KEY"
                return 0
            else
                echo "⚠️  Invalid P2P key found in shared volume, regenerating..."
            fi
        fi

        echo "📝 Generating new P2P private key for local collector..."

        # Generate Ed25519 private key
        PRIVATE_KEY_OUTPUT=$(python3 scripts/generate_p2p_key.py 2>/dev/null)

        # Extract the private key from output
        LOCAL_COLLECTOR_PRIVATE_KEY=$(echo "$PRIVATE_KEY_OUTPUT" | grep "LOCAL_COLLECTOR_PRIVATE_KEY=" | cut -d'=' -f2)

        if [ -z "$LOCAL_COLLECTOR_PRIVATE_KEY" ]; then
            echo "⚠️  Failed to generate P2P key, local collector integration may not work"
            return 1
        fi

        # Validate key format
        if [ ${#LOCAL_COLLECTOR_PRIVATE_KEY} -ne 128 ] || ! [[ "$LOCAL_COLLECTOR_PRIVATE_KEY" =~ ^[0-9a-fA-F]+$ ]]; then
            echo "⚠️  Generated P2P key format is invalid, local collector integration may not work"
            return 1
        fi

        echo "✅ Generated new P2P private key"

        # Create shared volume directory
        SHARED_KEYS_DIR="./shared-volume"
        mkdir -p "$SHARED_KEYS_DIR"

        # Write private key to shared volume
        echo "$LOCAL_COLLECTOR_PRIVATE_KEY" > "$SHARED_KEYS_DIR/p2p_private_key"
        chmod 600 "$SHARED_KEYS_DIR/p2p_private_key"

        # Create signal file to indicate key is ready
        echo "Generated P2P key ready" > "$SHARED_KEYS_DIR/p2p_ready"
        chmod 644 "$SHARED_KEYS_DIR/p2p_ready"

        echo "✅ P2P key written to shared volume for local collector"

        # Export for current session
        export LOCAL_COLLECTOR_PRIVATE_KEY
    else
        echo "✅ Using existing LOCAL_COLLECTOR_PRIVATE_KEY"
    fi
}

# Generate P2P key before config setup
generate_p2p_key

# Run autofill to setup config files
bash snapshotter_autofill.sh
if [ $? -ne 0 ]; then
    echo "❌ Config setup failed"
    exit 1
fi

# Print the version of the snapshotter
poetry run python -m snapshotter.version

# Continue with existing steps
poetry run python -m snapshotter.snapshotter_id_ping
ret_status=$?

if [ $ret_status -ne 0 ]; then
    exit 1
fi

# Set up traps for all possible exit scenarios
trap 'handle_exit' EXIT HUP INT QUIT ABRT TERM KILL

poetry run python -m snapshotter.system_event_detector
