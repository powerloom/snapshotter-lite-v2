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