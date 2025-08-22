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

echo "🔄 Starting collector connectivity checks..."

# Array of hosts to try
hosts=("localhost" "127.0.0.1" "0.0.0.0")
test_ping=false
test_namespace=false

# Determine which port checking tool to use
if command -v nc &> /dev/null; then
    PORT_CHECK_CMD="nc -z"
elif command -v netcat &> /dev/null; then
    PORT_CHECK_CMD="netcat -z"
else
    echo "🔄 nc not found, checking for curl..."
    if ! command -v curl &> /dev/null; then
        echo "❌ curl is not installed as well..."
        echo "⚠️ Please install either netcat or curl to continue"
        exit 1
    fi
    PORT_CHECK_CMD="curl -s --connect-timeout 5 telnet://"
fi

# Test port connectivity
for host in "${hosts[@]}"; do
    echo "  ⏳ Testing ${host}:${LOCAL_COLLECTOR_PORT}"
    if [[ "$PORT_CHECK_CMD" == *"curl"* ]]; then
        if $PORT_CHECK_CMD "${host}:${LOCAL_COLLECTOR_PORT}" 2>/dev/null; then
            test_ping=true
            break
        fi
    else
        if $PORT_CHECK_CMD "${host}" "${LOCAL_COLLECTOR_PORT}" 2>/dev/null; then
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
fi

# Final status check
if [ "$test_ping" = true ] && [ "$test_namespace" = true ]; then
    echo "✅ Collector is running and reachable"
    exit 100
else
    echo "⚠️  No active collector found - searching for available ports..."
    for port in {50051..51050}; do
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
