#!/bin/bash

# Source environment variables
if [ -z "$FULL_NAMESPACE" ]; then
    echo "FULL_NAMESPACE not found, please run build.sh first to set up environment"
    exit 1  # it is fine to exit with 1 here, as setup should not proceed past this
fi

# parse --env-file argument
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --env-file) ENV_FILE="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

source "$ENV_FILE"

# Set default values if not found in env
if [ -z "$LOCAL_COLLECTOR_PORT" ]; then
    export LOCAL_COLLECTOR_PORT=50051
fi

# Store configured port for fallback search
CONFIGURED_PORT=$LOCAL_COLLECTOR_PORT

echo "🔄 Starting collector connectivity checks..."

# Step 1: Check if collector container is running in the correct namespace
container_name="snapshotter-lite-local-collector-${FULL_NAMESPACE}"
if ! docker ps | grep -q "$container_name"; then
    echo "❌ Namespaced collector container not found: $container_name"
else
    echo "✅ Namespaced collector container running: $container_name"

    # Get the actual gRPC port from container's environment variables
    actual_port=$(docker inspect "${container_name}" 2>/dev/null | grep -o 'LOCAL_COLLECTOR_PORT=[^,]*' | cut -d'=' -f2 | tr -d '"')
    if [ -n "$actual_port" ]; then
        echo "🔍 Collector container gRPC port: $actual_port"
        # Update environment file with actual port
        sed -i".backup" "s/^LOCAL_COLLECTOR_PORT=.*/LOCAL_COLLECTOR_PORT=${actual_port}/" "${ENV_FILE}"
        LOCAL_COLLECTOR_PORT=$actual_port
        echo "✅ Updated LOCAL_COLLECTOR_PORT in environment file: $actual_port"
        exit 100
    else
        echo "⚠️ Could not determine gRPC port for collector container"
    fi
fi

# Step 2: No namespace container found - search for available ports
echo "⚠️  No active collector found using namespace - searching for available ports from $CONFIGURED_PORT to 51050..."

# Function to check if port is free
check_port_free() {
    local port=$1
    if command -v nc &> /dev/null; then
        if nc -z localhost "$port" 2>/dev/null; then
            return 1  # Port in use
        else
            return 0  # Port free
        fi
    elif command -v netcat &> /dev/null; then
        if netcat -z localhost "$port" 2>/dev/null; then
            return 1  # Port in use
        else
            return 0  # Port free
        fi
    else
        # Pure bash TCP connection test
        if timeout 1 bash -c "exec 3<>/dev/tcp/localhost/$port" 2>/dev/null; then
            return 1  # Port in use
        else
            return 0  # Port free
        fi
    fi
}

for port in $(seq $CONFIGURED_PORT 51050); do
    echo "  ⏳ Testing port $port"
    if check_port_free "$port"; then
        echo "✅ Found available port: $port"
        sed -i".backup" "s/^LOCAL_COLLECTOR_PORT=.*/LOCAL_COLLECTOR_PORT=${port}/" "${ENV_FILE}"
        break
    else
        echo "Port $port is in use"
    fi
done
exit 101
