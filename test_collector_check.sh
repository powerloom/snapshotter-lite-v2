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
    local expected_port_in_use=$2
    local test_description=$3
    
    echo "🧪 Test: $test_description"
    
    if [ "$nc_available" = "false" ]; then
        # Create a function that overrides the command -v behavior for nc
        command() {
            if [ "$2" = "nc" ]; then
                return 1
            fi
            builtin command "$@"
        }
        export -f command
        echo "  Disabled nc check via function override"
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
    return $TEST_RESULT
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

# Test 1: With nc, port free
run_test "true" "false" "With netcat, port is free"
cleanup_port

# Test 2: With nc, port in use
run_test "true" "true" "With netcat, port is in use"
cleanup_port

# Test 3: Without nc, port free
run_test "false" "false" "Without netcat, port is free"
cleanup_port

# Test 4: Without nc, port in use
run_test "false" "true" "Without netcat, port is in use"
cleanup_port

# Cleanup
echo "Cleaning up..."
rm -f test.env
unset -f command  # Ensure command function is unset

echo "Tests completed!"
