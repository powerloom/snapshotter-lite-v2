#!/bin/bash

# DSV Devnet Startup Script for Local Collector
# This script handles the complete DSV devnet onboarding flow:
# 1. Generate private key if needed
# 2. Register peer ID with protocol contract
# 3. Start local collector

set -e

echo "🚀 DSV Devnet Startup Script for Local Collector"
echo "=================================================="

# Configuration
RPC_URL="https://rpc-devnet.powerloom.dev"
CHAIN_ID="11167"
VALIDATOR_STATE_ADDRESS="0x3B5A0FB70ef68B5dd677C7d614dFB89961f97401"

# Check required environment variables
check_env() {
    echo "🔍 Checking environment variables..."

    if [ -z "$SIGNER_PRIVATE_KEY" ]; then
        echo "❌ SIGNER_PRIVATE_KEY environment variable is required"
        echo "   This should be the snapshotter signer key registered with your slot ID"
        exit 1
    fi

    if [ -z "$DATA_MARKET_NAME" ]; then
        echo "❌ DATA_MARKET_NAME environment variable is required"
        echo "   e.g., UNISWAPV3, UNISWAPV2, AAVEV3"
        exit 1
    fi

    echo "✅ Environment variables check passed"
}

# Generate private key if needed
generate_private_key() {
    echo "🔑 Checking P2P private key..."

    # Synchronization logic: Check if key exists in volume but not in env file
    if [ -z "$LOCAL_COLLECTOR_PRIVATE_KEY" ]; then
        # Check if P2P key exists in shared volume
        SHARED_KEY_FILE="./shared-volume/p2p_private_key"
        if [ -f "$SHARED_KEY_FILE" ]; then
            # Read the key from volume and validate it's a proper 128-character hex string
            VOLUME_KEY=$(cat "$SHARED_KEY_FILE" 2>/dev/null || echo "")
            if [ -n "$VOLUME_KEY" ] && [ ${#VOLUME_KEY} -eq 128 ] && [[ "$VOLUME_KEY" =~ ^[0-9a-fA-F]+$ ]]; then
                echo "🔄 Found valid P2P key in shared volume, synchronizing to environment file..."

                # Determine the correct env file name based on DATA_MARKET_NAME
                if [ -n "$DATA_MARKET_NAME" ]; then
                    # Look for existing env files with the current market configuration
                    ENV_FILES=$(ls .env-mainnet-*-${DATA_MARKET_NAME} 2>/dev/null || ls .env-devnet-*-${DATA_MARKET_NAME} 2>/dev/null || echo "")

                    if [ -n "$ENV_FILES" ]; then
                        # Use the first matching env file found
                        TARGET_ENV_FILE=$(echo "$ENV_FILES" | head -1)
                        echo "📝 Updating environment file: $TARGET_ENV_FILE"

                        # Append the P2P key to the env file
                        echo "LOCAL_COLLECTOR_PRIVATE_KEY=$VOLUME_KEY" >> "$TARGET_ENV_FILE"

                        echo "✅ Synchronized P2P key from volume to $TARGET_ENV_FILE"

                        # Export the key for current session
                        export LOCAL_COLLECTOR_PRIVATE_KEY="$VOLUME_KEY"

                        echo "🔑 Using synchronized P2P private key from shared volume"
                        return 0
                    else
                        echo "⚠️  No matching environment file found for market: $DATA_MARKET_NAME"
                        echo "   Available env files: $(ls .env-* 2>/dev/null || echo 'none')"
                        echo "   Will proceed with key generation..."
                    fi
                else
                    echo "⚠️  DATA_MARKET_NAME not set, cannot determine target env file"
                    echo "   Will proceed with key generation..."
                fi
            else
                echo "⚠️  Invalid or empty P2P key found in shared volume"
                echo "   Will proceed with key generation..."
            fi
        else
            echo "📝 No P2P key found in shared volume"
        fi
    fi

    if [ -z "$LOCAL_COLLECTOR_PRIVATE_KEY" ]; then
        echo "📝 No LOCAL_COLLECTOR_PRIVATE_KEY found, generating new one..."

        # Generate Ed25519 private key
        PRIVATE_KEY_OUTPUT=$(python3 scripts/generate_p2p_key.py)

        # Extract the private key from output
        LOCAL_COLLECTOR_PRIVATE_KEY=$(echo "$PRIVATE_KEY_OUTPUT" | grep "LOCAL_COLLECTOR_PRIVATE_KEY=" | cut -d'=' -f2)

        if [ -z "$LOCAL_COLLECTOR_PRIVATE_KEY" ]; then
            echo "❌ Failed to generate private key"
            exit 1
        fi

        echo "✅ Generated new P2P private key"
        echo "💾 Save this key for future use:"
        echo "   export LOCAL_COLLECTOR_PRIVATE_KEY=$LOCAL_COLLECTOR_PRIVATE_KEY"
        echo ""

        # Persist the generated key to shared volume
        echo "📝 Writing generated P2P key to shared volume for persistence..."

        # Create shared keys directory
        SHARED_KEYS_DIR="./shared-volume"
        mkdir -p "$SHARED_KEYS_DIR"

        # Write private key to shared volume
        echo "$LOCAL_COLLECTOR_PRIVATE_KEY" > "$SHARED_KEYS_DIR/p2p_private_key"
        chmod 600 "$SHARED_KEYS_DIR/p2p_private_key"

        # Create signal file to indicate key is ready
        echo "Generated P2P key ready" > "$SHARED_KEYS_DIR/p2p_ready"
        chmod 644 "$SHARED_KEYS_DIR/p2p_ready"

        echo "✅ Generated P2P key written to shared volume: $SHARED_KEYS_DIR/p2p_private_key"
        echo "🔗 Key will be available on container restarts via shared volume"

        # Export for current session
        export LOCAL_COLLECTOR_PRIVATE_KEY
    else
        echo "✅ Using existing LOCAL_COLLECTOR_PRIVATE_KEY"
    fi
}

# Register peer ID (optional step)
register_peer_id() {
    echo "🆔 Peer ID Registration (Optional)..."

    read -p "Do you want to register your peer ID with the protocol contract? (y/N): " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "📝 Registering peer ID with ValidatorState contract..."

        # Run peer ID registration script
        python3 scripts/register_peer_id.py

        if [ $? -eq 0 ]; then
            echo "✅ Peer ID registration completed"
        else
            echo "⚠️  Peer ID registration failed, but continuing with startup..."
        fi
    else
        echo "⏭️  Skipping peer ID registration"
    fi
}

# Start local collector
start_local_collector() {
    echo "🚀 Starting Local Collector..."

    # Check if we're in the right directory
    if [ ! -f "docker-compose-dev.yaml" ]; then
        echo "❌ docker-compose-dev.yaml not found. Are you in the snapshotter-lite-v2 directory?"
        exit 1
    fi

    # Start the services
    echo "🐳 Starting Docker services..."
    docker-compose -f docker-compose-dev.yaml up -d

    echo "✅ Local collector started successfully!"
    echo ""
    echo "📊 Monitoring commands:"
    echo "   docker-compose -f docker-compose-dev.yaml logs -f local-collector"
    echo "   docker-compose -f docker-compose-dev.yaml ps"
    echo ""
    echo "🛑 To stop: docker-compose -f docker-compose-dev.yaml down"
}

# Main execution
main() {
    echo "Starting DSV devnet onboarding flow..."
    echo ""

    check_env
    generate_private_key
    register_peer_id
    start_local_collector

    echo ""
    echo "🎉 DSV devnet onboarding completed!"
    echo "📖 For more information, see the DSV devnet documentation"
}

# Run main function
main "$@"