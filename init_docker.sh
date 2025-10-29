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
    echo "🔑 Checking P2P private key synchronization..."

    # Get namespace for env file naming
    NAMESPACE=${FULL_NAMESPACE:-"default"}
    ENV_FILE="/app/.env-${NAMESPACE}"
    SHARED_KEY_FILE="/keys/p2p_private_key"
    SHARED_KEYS_DIR="/keys"
    mkdir -p "$SHARED_KEYS_DIR"

    # Initialize variables
    local env_key=""
    local volume_key=""
    local final_key=""

    # 1. Read key from env file if it exists
    if [ -f "$ENV_FILE" ]; then
        env_key=$(grep "^LOCAL_COLLECTOR_PRIVATE_KEY=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'" || echo "")
        if [ -n "$env_key" ]; then
            echo "📄 Found P2P key in env file: ${env_key:0:16}..."
        fi
    fi

    # 2. Read key from shared volume if it exists
    if [ -f "$SHARED_KEY_FILE" ]; then
        volume_key=$(cat "$SHARED_KEY_FILE" 2>/dev/null || echo "")
        if [ -n "$volume_key" ]; then
            echo "💾 Found P2P key in shared volume: ${volume_key:0:16}..."
        fi
    fi

    # 3. Validate keys if they exist
    validate_key() {
        local key="$1"
        if [ -n "$key" ] && [ ${#key} -eq 64 ] && [[ "$key" =~ ^[0-9a-fA-F]+$ ]]; then
            return 0
        else
            echo "⚠️  Invalid P2P key format (expected 64 hex chars)"
            return 1
        fi
    }

    local env_key_valid=false
    local volume_key_valid=false

    if validate_key "$env_key"; then
        env_key_valid=true
        echo "✅ Env file key is valid"
    fi

    if validate_key "$volume_key"; then
        volume_key_valid=true
        echo "✅ Volume key is valid"
    fi

    # 4. Determine final key based on precedence (env file > volume > generate)
    if [ "$env_key_valid" = true ]; then
        # Env file takes highest precedence over everything
        echo "🔧 Using env file key (highest precedence)"
        final_key="$env_key"
    elif [ "$volume_key_valid" = true ]; then
        # Volume key takes precedence over generation
        echo "🔧 Using volume key (syncing to env file)"
        final_key="$volume_key"
    else
        # Generate new key if no valid keys found anywhere
        echo "📝 No valid P2P keys found, generating new key..."

        # Generate Ed25519 private key
        PRIVATE_KEY_OUTPUT=$(python3 scripts/generate_p2p_key.py 2>/dev/null)

        # Extract the private key from output
        final_key=$(echo "$PRIVATE_KEY_OUTPUT" | grep "LOCAL_COLLECTOR_PRIVATE_KEY=" | cut -d'=' -f2 | tr -d '"' | tr -d "'")

        if [ -z "$final_key" ] || ! validate_key "$final_key"; then
            echo "❌ Failed to generate valid P2P key"
            return 1
        fi

        echo "✅ Generated new P2P private key: ${final_key:0:16}..."
    fi

    # 5. Synchronization logic - env file always overwrites volume
    sync_needed=false

    # Sync to environment variable
    if [ "$LOCAL_COLLECTOR_PRIVATE_KEY" != "$final_key" ]; then
        export LOCAL_COLLECTOR_PRIVATE_KEY="$final_key"
        echo "🔄 Synced to environment variable"
        sync_needed=true
    fi

    # Sync to env file (if not already there from precedence check)
    if [ "$env_key" != "$final_key" ]; then
        # Backup existing env file
        if [ -f "$ENV_FILE" ]; then
            cp "$ENV_FILE" "${ENV_FILE}.backup.$(date +%s)"
        fi

        # Remove old key if exists
        if [ -n "$env_key" ] && [ -f "$ENV_FILE" ]; then
            sed -i.bak '/^LOCAL_COLLECTOR_PRIVATE_KEY=/d' "$ENV_FILE"
        fi

        # Add new key
        echo "LOCAL_COLLECTOR_PRIVATE_KEY=\"$final_key\"" >> "$ENV_FILE"
        echo "🔄 Synced to env file: $ENV_FILE"
        sync_needed=true
    fi

    # ALWAYS sync to shared volume (env file overwrites volume)
    if [ "$volume_key" != "$final_key" ]; then
        echo "$final_key" > "$SHARED_KEY_FILE"
        chmod 600 "$SHARED_KEY_FILE"
        echo "🔄 Overwrote shared volume with env file key: $SHARED_KEY_FILE"
        sync_needed=true
    fi

    
    # 6. Create/update signal file
    echo "P2P key synchronized: $(date)" > "$SHARED_KEYS_DIR/p2p_ready"
    chmod 644 "$SHARED_KEYS_DIR/p2p_ready"

    if [ "$sync_needed" = true ]; then
        echo "✅ P2P key bidirectional synchronization completed"
    else
        echo "✅ P2P key already synchronized across all locations"
    fi

    echo "📋 Final P2P key status:"
    echo "   Environment variable: ${LOCAL_COLLECTOR_PRIVATE_KEY:0:16}..."
    echo "   Env file: $([ -f "$ENV_FILE" ] && echo "✅ $(grep LOCAL_COLLECTOR_PRIVATE_KEY "$ENV_FILE" | cut -d'=' -f2 | tr -d '"' | tr -d "'" | head -c 16)..." || echo "❌ Not found")"
    echo "   Shared volume: $([ -f "$SHARED_KEY_FILE" ] && echo "✅ $(head -c 16 "$SHARED_KEY_FILE")..." || echo "❌ Not found")"
    echo "   Signal file: $([ -f "$SHARED_KEYS_DIR/p2p_ready" ] && echo "✅ Ready" || echo "❌ Not ready")"

    return 0
}

# Generate P2P private key if needed
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
