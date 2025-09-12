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
fi

# Final status check
if [ "$test_ping" = true ] && [ "$test_namespace" = true ]; then
    echo "✅ Collector is running and reachable on port ${LOCAL_COLLECTOR_PORT} and namespace ${FULL_NAMESPACE}"
    exit 100
else
    echo "⚠️  No active collector found"
    
    # Only search for alternative port if configured port is in use (test_ping=true)
    if [ "$test_ping" = true ]; then
        echo "⚠️  Configured port ${LOCAL_COLLECTOR_PORT} is in use - searching for other available ports..."
        for port in {50051..51050}; do
            if [ "$port" = "$LOCAL_COLLECTOR_PORT" ]; then
                continue  # Skip the port we know is in use
            fi
            
            port_is_free=true
            for host in "${hosts[@]}"; do
                if command -v nc &> /dev/null; then
                    if nc -z "${host}" "${port}" 2>/dev/null; then
                        port_is_free=false
                        break
                    fi
                elif command -v netcat &> /dev/null; then
                    if netcat -z "${host}" "${port}" 2>/dev/null; then
                        port_is_free=false
                        break
                    fi
                else
                    if timeout 1 bash -c "</dev/tcp/${host}/${port}" 2>/dev/null; then
                        port_is_free=false
                        break
                    fi
                fi
            done
            
            if [ "$port_is_free" = true ]; then
                echo "✅ Found available port: $port (replacing conflicting configured port ${LOCAL_COLLECTOR_PORT}) for namespace ${FULL_NAMESPACE}"
                sed -i".backup" "s/^LOCAL_COLLECTOR_PORT=.*/LOCAL_COLLECTOR_PORT=${port}/" "${ENV_FILE}"
                break
            fi
        done
    else
        echo "✅ Configured port ${LOCAL_COLLECTOR_PORT} is available for namespace ${FULL_NAMESPACE} - will use it for new collector"
    fi
    
    exit 101
fi
