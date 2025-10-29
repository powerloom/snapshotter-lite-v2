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

# Set PORT_CHECK_CMD for port search loop (same logic as above)
if command -v nc &> /dev/null; then
    PORT_CHECK_CMD="nc -z"
elif command -v netcat &> /dev/null; then
    PORT_CHECK_CMD="netcat -z"
else
    # Pure bash TCP connection test - available on all systems
    PORT_CHECK_CMD="timeout 1 bash -c '</dev/tcp/\$1/\$2'"
fi

echo "🔄 Starting collector connectivity checks..."

# Array of hosts to try
hosts=("localhost" "127.0.0.1" "0.0.0.0")
test_ping=false
test_namespace=false

# Test port connectivity using nc/netcat if available, otherwise use pure bash
for host in "${hosts[@]}"; do
    echo "  ⏳ Testing ${host}:${LOCAL_COLLECTOR_PORT}"
    
    if command -v nc &> /dev/null; then
        if nc -z "${host}" "${LOCAL_COLLECTOR_PORT}" 2>/dev/null; then
            test_ping=true
            break
        fi
    elif command -v netcat &> /dev/null; then
        if netcat -z "${host}" "${LOCAL_COLLECTOR_PORT}" 2>/dev/null; then
            test_ping=true
            break
        fi
    else
        # Pure bash TCP connection test - available on all systems
        if timeout 1 bash -c "</dev/tcp/${host}/${LOCAL_COLLECTOR_PORT}" 2>/dev/null; then
            test_ping=true
            break
        fi
    fi
done

# Test container status
container_name="snapshotter-lite-local-collector-${FULL_NAMESPACE}"
if ! docker ps | grep -q "$container_name"; then
    echo "❌ Collector container not found: $container_name"
else
    echo "✅ Collector container running: $container_name"
    test_namespace=true

    # Get the actual gRPC port from container's environment variables
    actual_port=$(docker inspect "${container_name}" 2>/dev/null | grep -o 'LOCAL_COLLECTOR_PORT=[^,]*' | cut -d'=' -f2 | tr -d '"')
    if [ -n "$actual_port" ]; then
        echo "🔍 Collector container gRPC port: $actual_port"

        # Update environment file with actual port (same logic as line 97)
        sed -i".backup" "s/^LOCAL_COLLECTOR_PORT=.*/LOCAL_COLLECTOR_PORT=${actual_port}/" "${ENV_FILE}"
        LOCAL_COLLECTOR_PORT=$actual_port
        echo "✅ Updated LOCAL_COLLECTOR_PORT in environment file: $actual_port"
    else
        echo "⚠️ Could not determine gRPC port for collector container"
    fi
fi

# Final status check
if [ "$test_ping" = true ] && [ "$test_namespace" = true ]; then
    echo "✅ Collector is running and reachable" 
    exit 100
else
    echo "⚠️  No active collector found - searching for available ports..."
    for port in $(seq $CONFIGURED_PORT 51050); do
        port_is_free=false
        if [[ "$PORT_CHECK_CMD" == *"curl"* ]]; then
            if ! $PORT_CHECK_CMD "localhost:$port" 2>/dev/null; then
                port_is_free=true
            fi
        else
            if ! $PORT_CHECK_CMD "localhost" "$port" 2>/dev/null; then
                port_is_free=true
            fi
        fi
        
        if [ "$port_is_free" = true ]; then
            echo "✅ Found available port: $port"
            sed -i".backup" "s/^LOCAL_COLLECTOR_PORT=.*/LOCAL_COLLECTOR_PORT=${port}/" "${ENV_FILE}"
            break
        fi
    done
    exit 101
fi
