#!/bin/bash

# Operator Key Generation Script for Local Collector
# This script generates a P2P private key and adds it to the environment file
# Used for one-time operator setup when LOCAL_COLLECTOR_PRIVATE_KEY is missing

set -e

echo "🔑 Local Collector P2P Key Generation for Operators"
echo "====================================================="

# Configuration
KEYGEN_IMAGE="powerloom/key-generator:latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Parse arguments
ENV_FILE=""
MARKET=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --env-file) ENV_FILE="$2"; shift ;;
        --market)
            MARKET="$2"
            # Auto-detect env file if not specified
            if [ -z "$ENV_FILE" ]; then
                ENV_FILE="$PROJECT_ROOT/.env-devnet-$MARKET"
                if [ ! -f "$ENV_FILE" ]; then
                    ENV_FILE="$PROJECT_ROOT/.env-mainnet-$MARKET"
                fi
            fi
            shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Validate inputs
validate_inputs() {
    echo "🔍 Validating inputs..."

    if [ -z "$ENV_FILE" ]; then
        echo "❌ No environment file specified or found"
        echo "   Usage: $0 --env-file <path> OR $0 --market <MARKET>"
        echo "   Example: $0 --env-file .env-devnet-UNISWAPV3-ETH"
        echo "            $0 --market UNISWAPV3-ETH"
        exit 1
    fi

    if [ ! -f "$ENV_FILE" ]; then
        echo "❌ Environment file not found: $ENV_FILE"
        echo "   Please create the environment file first using configure-environment.sh"
        exit 1
    fi

    echo "✅ Environment file: $ENV_FILE"

    # Check Docker availability
    if ! command -v docker &> /dev/null; then
        echo "❌ Docker is not installed or not in PATH"
        echo "   Please install Docker to use this script"
        exit 1
    fi

    echo "✅ Docker is available"
}

# Check for existing key (handles commented lines properly)
check_existing_key() {
    echo "🔍 Checking for existing P2P private key..."

    # Look for uncommented LOCAL_COLLECTOR_PRIVATE_KEY with actual value
    # This regex matches: LOCAL_COLLECTOR_PRIVATE_KEY=some_value (not starting with #)
    if grep -q "^[[:space:]]*LOCAL_COLLECTOR_PRIVATE_KEY=" "$ENV_FILE"; then
        # Extract the key value
        EXISTING_KEY=$(grep "^[[:space:]]*LOCAL_COLLECTOR_PRIVATE_KEY=" "$ENV_FILE" | head -1 | cut -d'=' -f2)

        if [ -n "$EXISTING_KEY" ]; then
            echo "✅ Found existing P2P private key in $ENV_FILE"
            echo "   Key starts with: ${EXISTING_KEY:0:8}..."

            # Validate key format (128 hex characters)
            if [[ ${#EXISTING_KEY} -eq 128 && $EXISTING_KEY =~ ^[a-fA-F0-9]{128}$ ]]; then
                echo "✅ Existing key format is valid (128 hex characters)"
                echo "🎯 No key generation needed - using existing key"
                return 0
            else
                echo "⚠️  Existing key format is invalid (${#EXISTING_KEY} characters, expected 128 hex)"
                echo "   Will generate a new key..."
                return 1
            fi
        else
            echo "⚠️  Found LOCAL_COLLECTOR_PRIVATE_KEY line but no value"
            return 1
        fi
    else
        echo "ℹ️  No LOCAL_COLLECTOR_PRIVATE_KEY found in $ENV_FILE"
        return 1
    fi
}

# Build or pull key generator image
ensure_keygen_image() {
    echo "🐳 Ensuring key generator Docker image..."

    # Check if image exists locally
    if docker images --format "table {{.Repository}}:{{.Tag}}" | grep -q "^$KEYGEN_IMAGE$"; then
        echo "✅ Key generator image found locally: $KEYGEN_IMAGE"
    else
        echo "📦 Building key generator image locally..."

        # Build from local Dockerfile
        DOCKERFILE_PATH="$PROJECT_ROOT/../key_generator/Dockerfile"
        if [ ! -f "$DOCKERFILE_PATH" ]; then
            echo "❌ Key generator Dockerfile not found: $DOCKERFILE_PATH"
            exit 1
        fi

        # Build the image with a local tag
        LOCAL_TAG="key-generator:local"
        if docker build -t "$LOCAL_TAG" -f "$DOCKERFILE_PATH" "$PROJECT_ROOT/../key_generator/"; then
            echo "✅ Built key generator image locally: $LOCAL_TAG"
            KEYGEN_IMAGE="$LOCAL_TAG"
        else
            echo "❌ Failed to build key generator image"
            exit 1
        fi
    fi
}

# Generate new key using Docker
generate_key() {
    echo "🔑 Generating new P2P private key..."

    # Create temporary file for output
    TEMP_OUTPUT=$(mktemp)

    # Run the key generator container
    if docker run --rm "$KEYGEN_IMAGE" > "$TEMP_OUTPUT" 2>&1; then
        echo "✅ Key generation completed"

        # Extract the private key from output - look for exact 128-character hex string
        PRIVATE_KEY=$(grep "Generated Private Key (hex):" "$TEMP_OUTPUT" | sed 's/.*: //' | awk '{print $1}' || echo "")

        if [ -z "$PRIVATE_KEY" ]; then
            # Fallback: extract any 128-character hex string using a simpler method
            PRIVATE_KEY=$(grep -o "[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]" "$TEMP_OUTPUT" | head -1 || echo "")
        fi

        # Display key extraction info for debugging
        if [ -n "$PRIVATE_KEY" ]; then
            echo "✅ Extracted private key: ${PRIVATE_KEY:0:8}..."
        else
            echo "❌ Failed to extract private key"
            echo "📄 Key generator output:"
            cat "$TEMP_OUTPUT"
        fi

        # Clean up temp file
        rm -f "$TEMP_OUTPUT"

        if [ -n "$PRIVATE_KEY" ]; then
            echo "✅ Extracted private key: ${PRIVATE_KEY:0:8}..."

            # Validate key format
            if [[ ${#PRIVATE_KEY} -eq 128 && $PRIVATE_KEY =~ ^[a-fA-F0-9]{128}$ ]]; then
                echo "✅ Key format validation passed (128 hex characters)"
                echo "$PRIVATE_KEY"
                return 0
            else
                echo "❌ Invalid key format: ${#PRIVATE_KEY} characters, expected 128 hex"
                echo "   Key: $PRIVATE_KEY"
                return 1
            fi
        else
            echo "❌ Failed to extract private key from output"
            echo "   Full output saved to /tmp/keygen_debug.log"
            cat "$TEMP_OUTPUT" > /tmp/keygen_debug.log
            rm -f "$TEMP_OUTPUT"
            return 1
        fi
    else
        echo "❌ Key generation failed"
        echo "   Check Docker logs and ensure the key generator image is working"
        rm -f "$TEMP_OUTPUT"
        return 1
    fi
}

# Add key to environment file
add_key_to_env() {
    local key="$1"

    echo "📝 Adding P2P private key to $ENV_FILE..."

    # Create backup of original file
    BACKUP_FILE="${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$ENV_FILE" "$BACKUP_FILE"
    echo "📦 Created backup: $BACKUP_FILE"

    # Remove any existing commented or uncommented LOCAL_COLLECTOR_PRIVATE_KEY lines
    sed -i.tmp '/^[[:space:]]*#*[[:space:]]*LOCAL_COLLECTOR_PRIVATE_KEY=/d' "$ENV_FILE"

    # Add the new key at the end of the file
    echo "" >> "$ENV_FILE"
    echo "# Local Collector P2P Private Key - Generated by setup_operator_keys.sh" >> "$ENV_FILE"
    echo "LOCAL_COLLECTOR_PRIVATE_KEY=$key" >> "$ENV_FILE"

    # Clean up temp file
    rm -f "${ENV_FILE}.tmp"

    echo "✅ P2P private key added to $ENV_FILE"
    echo "   Key: ${key:0:8}... (first 8 characters shown)"
}

# Main execution
main() {
    echo "Starting P2P key generation for operators..."
    echo ""

    validate_inputs

    # Check if key already exists and is valid
    if check_existing_key; then
        echo "🎉 Setup completed - using existing valid key"
        exit 0
    fi

    # Ensure key generator image is available
    ensure_keygen_image

    # Generate new key
    PRIVATE_KEY=$(generate_key)
    if [ $? -ne 0 ] || [ -z "$PRIVATE_KEY" ]; then
        echo "❌ Failed to generate P2P private key"
        exit 1
    fi

    # Add key to environment file
    add_key_to_env "$PRIVATE_KEY"

    echo ""
    echo "🎉 P2P key generation completed successfully!"
    echo ""
    echo "📋 Summary:"
    echo "   ✅ Environment file: $ENV_FILE"
    echo "   ✅ Private key: ${PRIVATE_KEY:0:8}...${PRIVATE_KEY: -8}"
    echo "   ✅ Key length: ${#PRIVATE_KEY} characters"
    echo "   ✅ Format: 128-character hex string"
    echo ""
    echo "🚀 Next steps:"
    echo "   1. Start the services: docker-compose -f docker-compose-dev.yaml up -d"
    echo "   2. Monitor logs: docker-compose -f docker-compose-dev.yaml logs -f"
    echo ""
    echo "💡 Important:"
    echo "   - Save the $ENV_FILE file - it contains your private key"
    echo "   - The same key will be used on all container restarts"
    echo "   - Keep the private key secure and backed up"
}

# Run main function
main "$@"