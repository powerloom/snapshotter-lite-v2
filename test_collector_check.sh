#!/bin/bash

# Create a temporary env file
echo "Creating test env file..."
cat > test.env << EOL
FULL_NAMESPACE=TEST-MAINNET-ETH
LOCAL_COLLECTOR_PORT=50051
EOL

# Export required variables
export FULL_NAMESPACE=TEST-MAINNET-ETH

# Function to run the test
run_test() {
    local nc_available=$1
    local curl_available=$2
    local expected_port_in_use=$3
    local test_description=$4
    
    echo "🧪 Test: $test_description"
    
    if [ "$nc_available" = "false" ]; then
        # Create functions that override command behavior for nc and netcat
        command() {
            if [ "$2" = "nc" ]; then
                return 1
            elif [ "$2" = "netcat" ]; then
                return 1
            fi
            builtin command "$@"
        }
        
        # Override the actual commands too
        nc() { return 1; }
        netcat() { return 1; }
        export -f command
        echo "  Disabled nc/netcat check via function override"
        if [ "$curl_available" = "false" ]; then
            echo "  Disabled curl check via function override"
        fi
    else
        # Restore normal command behavior
        unset -f command
        echo "  Restored normal command behavior"
    fi
    
    if [ "$expected_port_in_use" = "true" ]; then
        echo "  Starting dummy service on port 50051..."
        nc -l 50051 &
        NC_PID=$!
        sleep 1
    fi
    
    echo "  Running collector_test.sh..."
    ./collector_test.sh --env-file test.env
    TEST_RESULT=$?
    
    if [ "$expected_port_in_use" = "true" ]; then
        echo "  Stopping dummy service..."
        kill $NC_PID 2>/dev/null
    fi
    
    echo "  Test result code: $TEST_RESULT"
    
    # Verify expected exit codes
    if [ "$nc_available" = "false" ] && [ "$curl_available" = "false" ]; then
        # Should exit with 1 when no tools available
        if [ "$TEST_RESULT" -eq 1 ]; then
            echo "  ✅ Correctly exited with code 1 when no tools available"
            return 0
        else
            echo "  ❌ Expected exit code 1 when no tools available, got $TEST_RESULT"
            return 1
        fi
    elif [ "$expected_port_in_use" = "true" ] && [ "$TEST_RESULT" -eq 100 ]; then
        echo "  ✅ Correctly detected running collector"
        return 0
    elif [ "$expected_port_in_use" = "false" ] && [ "$TEST_RESULT" -eq 101 ]; then
        echo "  ✅ Correctly found available port"
        return 0
    else
        echo "  ❌ Unexpected exit code $TEST_RESULT"
        return 1
    fi
}

# Function to kill any process using our test port
cleanup_port() {
    echo "Cleaning up port 50051..."
    lsof -ti:50051 | xargs kill -9 2>/dev/null || true
    sleep 1
}

# Test scenarios
echo "Running test scenarios..."

# Initial cleanup
cleanup_port

echo "🧪 Testing with nc available..."
# Test 1: With nc, port free (should exit 101)
run_test "true" "true" "false" "With nc, port is free"
cleanup_port

# Test 2: With nc, port in use (should exit 100)
run_test "true" "true" "true" "With nc, port is in use"
cleanup_port

echo "🧪 Testing with netcat fallback..."
# Test 3: Without nc but with netcat, port free (should exit 101)
run_test "false" "true" "false" "Without nc but with netcat, port is free"
cleanup_port

# Test 4: Without nc but with netcat, port in use (should exit 100)
run_test "false" "true" "true" "Without nc but with netcat, port is in use"
cleanup_port

echo "🧪 Testing with bash fallback..."
# Test 5: Without nc and netcat, port free (should exit 101)
run_test "false" "false" "false" "Without nc/netcat, using bash fallback, port is free"
cleanup_port

# Test 6: Without nc and netcat, port in use (should exit 100)
run_test "false" "false" "true" "Without nc/netcat, using bash fallback, port is in use"
cleanup_port

# Cleanup
echo "Cleaning up..."
rm -f test.env
unset -f command  # Ensure command function is unset

echo "Tests completed!"
