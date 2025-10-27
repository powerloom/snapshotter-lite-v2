#!/bin/bash

# Initial variable declarations
DOCKER_NETWORK_PRUNE=false
SETUP_COMPLETE=true
SKIP_CREDENTIAL_UPDATE=false
NO_COLLECTOR=false
OVERRIDE_DEFAULTS_SCRIPT_FLAG=false
DEVNET_MODE=false
DOCKER_MODE=false
RESULT_FILE=""

# GitHub configuration URL
MARKETS_CONFIG_URL="https://raw.githubusercontent.com/powerloom/curated-datamarkets/refs/heads/feat/uniswapv3/sources.json"

# Dynamic defaults (will be populated from GitHub API)
DEFAULT_POWERLOOM_CHAIN=""
DEFAULT_SOURCE_CHAIN=""
DEFAULT_NAMESPACE=""
DEFAULT_POWERLOOM_RPC_URL=""
DEFAULT_PROTOCOL_STATE_CONTRACT=""
DEFAULT_DATA_MARKET_CONTRACT=""
DEFAULT_SNAPSHOT_CONFIG_REPO=""
DEFAULT_SNAPSHOT_CONFIG_REPO_BRANCH=""
DEFAULT_SNAPSHOT_CONFIG_REPO_COMMIT=""
DEFAULT_SNAPSHOTTER_COMPUTE_REPO=""
DEFAULT_SNAPSHOTTER_COMPUTE_REPO_BRANCH=""
DEFAULT_SNAPSHOTTER_COMPUTE_REPO_COMMIT=""
DEFAULT_CONNECTION_REFRESH_INTERVAL_SEC=""
DEFAULT_TELEGRAM_NOTIFICATION_COOLDOWN=""

DEFAULT_DEVNET_POWERLOOM_CHAIN=""
DEFAULT_DEVNET_SOURCE_CHAIN=""
DEFAULT_DEVNET_NAMESPACE=""
DEFAULT_DEVNET_POWERLOOM_RPC_URL=""
DEFAULT_DEVNET_PROTOCOL_STATE_CONTRACT=""
DEFAULT_DEVNET_SNAPSHOT_CONFIG_REPO=""
DEFAULT_DEVNET_SNAPSHOT_CONFIG_REPO_BRANCH=""
DEFAULT_DEVNET_SNAPSHOT_CONFIG_REPO_COMMIT=""
DEFAULT_DEVNET_SNAPSHOTTER_COMPUTE_REPO=""
DEFAULT_DEVNET_SNAPSHOTTER_COMPUTE_REPO_BRANCH=""
DEFAULT_DEVNET_SNAPSHOTTER_COMPUTE_REPO_COMMIT=""
DEFAULT_DEVNET_CONNECTION_REFRESH_INTERVAL_SEC=""
DEFAULT_DEVNET_TELEGRAM_NOTIFICATION_COOLDOWN=""

# Global variables for storing fetched configuration
MARKETS_CONFIG_JSON=""

# --- Global Variables ---
ENV_FILE_PATH=""
FILE_WAS_NEWLY_CREATED=false
CLEANUP_ENV_FILE_ON_ABORT=false
TARGET_ENV_FILE_FOR_CLEANUP=""

# Error handling and cleanup functions
handle_error() {
    local exit_code=$?
    if [ $exit_code -lt 100 ]; then
        echo "Error on line $1: Command exited with status $exit_code"
        exit $exit_code
    fi
    return $exit_code
}

final_cleanup_handler() {
    find . -name "*.backup" -type f -delete
    if [ "$CLEANUP_ENV_FILE_ON_ABORT" = true ] && [ -n "$TARGET_ENV_FILE_FOR_CLEANUP" ] && [ -f "$TARGET_ENV_FILE_FOR_CLEANUP" ] && [ "$SETUP_COMPLETE" = false ]; then
        rm -f "$TARGET_ENV_FILE_FOR_CLEANUP"
        echo "🗑️  Setup was interrupted or incomplete. Deleted partially created $TARGET_ENV_FILE_FOR_CLEANUP file."
    elif [ "$SETUP_COMPLETE" = false ] && [ -n "$ENV_FILE_PATH" ] && [ "$ENV_FILE_PATH" != "$TARGET_ENV_FILE_FOR_CLEANUP" ]; then
        echo "⚠️  Setup incomplete or aborted. Please review $ENV_FILE_PATH as it might be in an inconsistent state."
    elif [ "$SETUP_COMPLETE" = false ] && [ -z "$TARGET_ENV_FILE_FOR_CLEANUP" ]; then
        echo "⚠️  Setup incomplete or aborted."
    fi
}

trap 'handle_error $LINENO' ERR
trap final_cleanup_handler EXIT

# Function to parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --docker-network-prune) DOCKER_NETWORK_PRUNE=true; shift ;;
            --skip-credential-update) SKIP_CREDENTIAL_UPDATE=true; shift ;;
            --no-collector) NO_COLLECTOR=true; shift ;;
            --override) OVERRIDE_DEFAULTS_SCRIPT_FLAG=true; shift ;;
            --devnet) DEVNET_MODE=true; shift ;;
            --docker-mode) DOCKER_MODE=true; shift ;;
            --result-file) RESULT_FILE=$2; shift 2 ;;
            *)
                shift
                ;;
        esac
    done
}

# Function to safely parse configuration output into variables
parse_config_vars() {
    local config_output="$1"
    
    CHAIN_RPC_URL=""
    DATA_MARKET_CONTRACT=""
    PROTOCOL_STATE_CONTRACT=""
    SNAPSHOT_CONFIG_REPO=""
    SNAPSHOT_CONFIG_REPO_BRANCH=""
    SNAPSHOT_CONFIG_REPO_COMMIT=""
    SNAPSHOTTER_COMPUTE_REPO=""
    SNAPSHOTTER_COMPUTE_REPO_BRANCH=""
    SNAPSHOTTER_COMPUTE_REPO_COMMIT=""
    SOURCE_CHAIN=""
    
    while IFS= read -r line; do
        if [ -n "$line" ] && [[ "$line" == *"="* ]]; then
            case "$line" in
                CHAIN_RPC_URL=*) CHAIN_RPC_URL="${line#CHAIN_RPC_URL=}" ;; 
                DATA_MARKET_CONTRACT=*) DATA_MARKET_CONTRACT="${line#DATA_MARKET_CONTRACT=}" ;; 
                PROTOCOL_STATE_CONTRACT=*) PROTOCOL_STATE_CONTRACT="${line#PROTOCOL_STATE_CONTRACT=}" ;; 
                SNAPSHOT_CONFIG_REPO=*) SNAPSHOT_CONFIG_REPO="${line#SNAPSHOT_CONFIG_REPO=}" ;; 
                SNAPSHOT_CONFIG_REPO_BRANCH=*) SNAPSHOT_CONFIG_REPO_BRANCH="${line#SNAPSHOT_CONFIG_REPO_BRANCH=}" ;; 
                SNAPSHOT_CONFIG_REPO_COMMIT=*) SNAPSHOT_CONFIG_REPO_COMMIT="${line#SNAPSHOT_CONFIG_REPO_COMMIT=}" ;; 
                SNAPSHOTTER_COMPUTE_REPO=*) SNAPSHOTTER_COMPUTE_REPO="${line#SNAPSHOTTER_COMPUTE_REPO=}" ;; 
                SNAPSHOTTER_COMPUTE_REPO_BRANCH=*) SNAPSHOTTER_COMPUTE_REPO_BRANCH="${line#SNAPSHOTTER_COMPUTE_REPO_BRANCH=}" ;; 
                SNAPSHOTTER_COMPUTE_REPO_COMMIT=*) SNAPSHOTTER_COMPUTE_REPO_COMMIT="${line#SNAPSHOTTER_COMPUTE_REPO_COMMIT=}" ;; 
                SOURCE_CHAIN=*) SOURCE_CHAIN="${line#SOURCE_CHAIN=}" ;; 
            esac
        fi
    done <<< "$config_output"
}

# Function to check if jq is available
has_jq() {
    command -v jq >/dev/null 2>&1
}

# Function to extract chain configuration using jq
extract_chain_config_jq() {
    local chain_name="$1"
    local market_name="$2"
    
    if [ -z "$MARKETS_CONFIG_JSON" ]; then return 1; fi
    
    local jq_filter=".[] | select(.powerloomChain.name == \"$chain_name\") | { rpcURL: .powerloomChain.rpcURL, market: (.dataMarkets[]? | select(.name == \"$market_name\")) }"
    
    local result
    if ! result=$(echo "$MARKETS_CONFIG_JSON" | jq -c "$jq_filter" 2>&1); then
        echo "⚠️  jq parsing failed for chain: $chain_name, market: $market_name" >&2
        echo "🔍 jq error: $result" >&2
        return 1
    fi
    
    if [ "$result" = "null" ] || [ -z "$result" ] || [ "$result" = "{}" ]; then return 1; fi
    
    local rpc_url=$(echo "$result" | jq -r '.rpcURL // empty')
    local contract_addr=$(echo "$result" | jq -r '.market.contractAddress // empty')
    local protocol_state=$(echo "$result" | jq -r '.market.powerloomProtocolStateContractAddress // empty')
    local config_repo=$(echo "$result" | jq -r '.market.config.repo // empty')
    local config_branch=$(echo "$result" | jq -r '.market.config.branch // empty')
    local config_commit=$(echo "$result" | jq -r '.market.config.commit // empty')
    local compute_repo=$(echo "$result" | jq -r '.market.compute.repo // empty')
    local compute_branch=$(echo "$result" | jq -r '.market.compute.branch // empty')
    local compute_commit=$(echo "$result" | jq -r '.market.compute.commit // empty')
    local source_chain=$(echo "$result" | jq -r '.market.sourceChain // empty')
    local sequencer_addr=$(echo "$result" | jq -r '.market.sequencer // empty')
    
    if [[ "$source_chain" == *"-"* ]]; then source_chain="${source_chain%%-*}"; fi
    
    [ -n "$rpc_url" ] && echo "CHAIN_RPC_URL=$rpc_url"
    [ -n "$contract_addr" ] && echo "DATA_MARKET_CONTRACT=$contract_addr"
    [ -n "$protocol_state" ] && echo "PROTOCOL_STATE_CONTRACT=$protocol_state"
    [ -n "$config_repo" ] && echo "SNAPSHOT_CONFIG_REPO=$config_repo"
    [ -n "$config_branch" ] && echo "SNAPSHOT_CONFIG_REPO_BRANCH=$config_branch"
    [ -n "$config_commit" ] && echo "SNAPSHOT_CONFIG_REPO_COMMIT=$config_commit"
    [ -n "$compute_repo" ] && echo "SNAPSHOTTER_COMPUTE_REPO=$compute_repo"
    [ -n "$compute_branch" ] && echo "SNAPSHOTTER_COMPUTE_REPO_BRANCH=$compute_branch"
    [ -n "$compute_commit" ] && echo "SNAPSHOTTER_COMPUTE_REPO_COMMIT=$compute_commit"
    [ -n "$source_chain" ] && echo "SOURCE_CHAIN=$source_chain"
    [ -n "$sequencer_addr" ] && echo "BOOTSTRAP_NODE_ADDR=$sequencer_addr"
}

# Function to extract chain configuration
extract_chain_config() {
    if ! has_jq; then
        echo "❌ Error: jq is required but not installed." >&2
        return 1
    fi
    extract_chain_config_jq "$1" "$2"
}

# Function to fetch markets configuration from GitHub
fetch_markets_config() {
    echo "🌐 Fetching latest protocol state and data market configuration from GitHub..."
    if command -v curl >/dev/null 2>&1; then
        MARKETS_CONFIG_JSON=$(curl -s --connect-timeout 10 --max-time 30 "$MARKETS_CONFIG_URL")
    elif command -v wget >/dev/null 2>&1;
     then
        MARKETS_CONFIG_JSON=$(wget -qO- --timeout=30 --connect-timeout=10 "$MARKETS_CONFIG_URL")
    else
        echo "⚠️  Neither curl nor wget found. Exiting..."
        exit 1
    fi
    
    if [ -z "$MARKETS_CONFIG_JSON" ] || ! echo "$MARKETS_CONFIG_JSON" | jq -e . >/dev/null 2>&1;
     then
        echo "⚠️  Failed to fetch or parse configuration from GitHub. Exiting..."
        exit 1
    fi
    echo "✅ Successfully fetched protocol state and data market configurations."
}

# Function to initialize default configuration values
initialize_default_config() {
    if ! fetch_markets_config; then exit 1; fi
    
    echo "🔧 Initializing default configuration from GitHub data..."

    # For mainnet - find the first available chain and its first data market
    local first_mainnet_chain=$(echo "$MARKETS_CONFIG_JSON" | jq -r '.[].powerloomChain.name | select(startswith("mainnet")) | select(. != null)' | head -1)
    if [ -n "$first_mainnet_chain" ]; then
        local first_market_on_chain=$(echo "$MARKETS_CONFIG_JSON" | jq -r ".[] | select(.powerloomChain.name == \"$first_mainnet_chain\") | .dataMarkets[0].name // \"UNISWAPV2\"" | head -1)
        local mainnet_config=$(extract_chain_config "$first_mainnet_chain" "$first_market_on_chain")
        if [ -n "$mainnet_config" ]; then
            parse_config_vars "$mainnet_config"
            DEFAULT_POWERLOOM_CHAIN="$first_mainnet_chain"
            DEFAULT_SOURCE_CHAIN="$SOURCE_CHAIN"
            DEFAULT_NAMESPACE="$first_market_on_chain"
            DEFAULT_POWERLOOM_RPC_URL="$CHAIN_RPC_URL"
            DEFAULT_PROTOCOL_STATE_CONTRACT="$PROTOCOL_STATE_CONTRACT"
            DEFAULT_DATA_MARKET_CONTRACT="$DATA_MARKET_CONTRACT"
            DEFAULT_SNAPSHOT_CONFIG_REPO="$SNAPSHOT_CONFIG_REPO"
            DEFAULT_SNAPSHOT_CONFIG_REPO_BRANCH="$SNAPSHOT_CONFIG_REPO_BRANCH"
            DEFAULT_SNAPSHOT_CONFIG_REPO_COMMIT="$SNAPSHOT_CONFIG_REPO_COMMIT"
            DEFAULT_SNAPSHOTTER_COMPUTE_REPO="$SNAPSHOTTER_COMPUTE_REPO"
            DEFAULT_SNAPSHOTTER_COMPUTE_REPO_BRANCH="$SNAPSHOTTER_COMPUTE_REPO_BRANCH"
            DEFAULT_SNAPSHOTTER_COMPUTE_REPO_COMMIT="$SNAPSHOTTER_COMPUTE_REPO_COMMIT"
            DEFAULT_CONNECTION_REFRESH_INTERVAL_SEC="60"
            DEFAULT_TELEGRAM_NOTIFICATION_COOLDOWN="300"
        fi
    fi

    # For devnet - find the first available chain and its first data market
    local first_devnet_chain=$(echo "$MARKETS_CONFIG_JSON" | jq -r '.[].powerloomChain.name | select(startswith("devnet")) | select(. != null)' | head -1)
    if [ -n "$first_devnet_chain" ]; then
        local first_market_on_devnet=$(echo "$MARKETS_CONFIG_JSON" | jq -r ".[] | select(.powerloomChain.name == \"$first_devnet_chain\") | .dataMarkets[0].name // \"UNISWAPV2\"" | head -1)
        local devnet_config=$(extract_chain_config "$first_devnet_chain" "$first_market_on_devnet")
        if [ -n "$devnet_config" ]; then
            parse_config_vars "$devnet_config"
            DEFAULT_DEVNET_POWERLOOM_CHAIN="$first_devnet_chain"
            DEFAULT_DEVNET_SOURCE_CHAIN="$SOURCE_CHAIN"
            DEFAULT_DEVNET_NAMESPACE="$first_market_on_devnet"
            DEFAULT_DEVNET_POWERLOOM_RPC_URL="$CHAIN_RPC_URL"
            DEFAULT_DEVNET_PROTOCOL_STATE_CONTRACT="$PROTOCOL_STATE_CONTRACT"
            DEFAULT_DEVNET_SNAPSHOT_CONFIG_REPO="$SNAPSHOT_CONFIG_REPO"
            DEFAULT_DEVNET_SNAPSHOT_CONFIG_REPO_BRANCH="$SNAPSHOT_CONFIG_REPO_BRANCH"
            DEFAULT_DEVNET_SNAPSHOT_CONFIG_REPO_COMMIT="$SNAPSHOT_CONFIG_REPO_COMMIT"
            DEFAULT_DEVNET_SNAPSHOTTER_COMPUTE_REPO="$SNAPSHOTTER_COMPUTE_REPO"
            DEFAULT_DEVNET_SNAPSHOTTER_COMPUTE_REPO_BRANCH="$SNAPSHOTTER_COMPUTE_REPO_BRANCH"
            DEFAULT_DEVNET_SNAPSHOTTER_COMPUTE_REPO_COMMIT="$SNAPSHOTTER_COMPUTE_REPO_COMMIT"
            DEFAULT_DEVNET_CONNECTION_REFRESH_INTERVAL_SEC="60"
            DEFAULT_DEVNET_TELEGRAM_NOTIFICATION_COOLDOWN="300"
        fi
    fi
}

# Helper function to mask sensitive values for logging
mask_sensitive_value() {
    local name="$1"
    local value="$2"
    if [[ "$name" == "SIGNER_ACCOUNT_PRIVATE_KEY" ]] || [[ "$name" == "TELEGRAM_CHAT_ID" ]]; then
        echo "<HIDDEN>"
    else
        echo "$value"
    fi
}

# Helper function to update a variable in a file or append it if it doesn't exist
update_or_append_var() {
    local var_name="$1"
    local var_value="$2"
    local target_file="$3"

    if grep -q "^${var_name}=" "$target_file"; then
        local existing_var_value
        existing_var_value=$(grep "^${var_name}=" "$target_file" | cut -d'=' -f2-)
        if [ "$var_value" != "$existing_var_value" ]; then
            local masked_new=$(mask_sensitive_value "$var_name" "$var_value")
            echo "🔍 Updating $var_name in $target_file to: $masked_new"
            local sed_safe_var_value=$(printf '%s
' "$var_value" | sed -e 's/[\/&]/\\&/g')
            sed -i".backup" "s#^${var_name}=.*#${var_name}=${sed_safe_var_value}#" "$target_file"
        fi
    else
        local masked_value=$(mask_sensitive_value "$var_name" "$var_value")
        echo "🔍 Adding new variable $var_name to $target_file with value: $masked_value"
        echo "${var_name}=${var_value}" >> "$target_file"
    fi
}

# Function to dynamically select a data market and configure it
select_market_and_configure() {
    local is_devnet_mode="${1:-false}"
    local selected_chain_name
    local selected_market_name

    if [ "$is_devnet_mode" = "true" ]; then
        local devnet_chains
        mapfile -t devnet_chains < <(echo "$MARKETS_CONFIG_JSON" | jq -r '.[].powerloomChain.name | select(startswith("devnet"))' | sort -u)
        
        if [ "${#devnet_chains[@]}" -eq 0 ]; then
            echo "❌ No devnet chains found in the configuration."
            exit 1
        elif [ "${#devnet_chains[@]}" -eq 1 ]; then
            selected_chain_name="${devnet_chains[0]}"
        else
            echo "🔍 Select a Powerloom devnet chain:"
            select chain_choice in "${devnet_chains[@]}"; do
                if [ -n "$chain_choice" ]; then
                    selected_chain_name="$chain_choice"
                    break
                else
                    echo "❌ Invalid selection. Please try again."
                fi
            done
        fi
    else
        local chains
        mapfile -t chains < <(echo "$MARKETS_CONFIG_JSON" | jq -r '.[].powerloomChain.name' | sort -u)
        echo "🔍 Select a Powerloom chain:"
        select chain_choice in "${chains[@]}"; do
            if [ -n "$chain_choice" ]; then
                selected_chain_name="$chain_choice"
                break
            else
                echo "❌ Invalid selection. Please try again."
            fi
        done
    fi

    local markets
    mapfile -t markets < <(echo "$MARKETS_CONFIG_JSON" | jq -r ".[] | select(.powerloomChain.name == \"$selected_chain_name\") | .dataMarkets[].name" | sort)
    echo "🔍 Select a data market on '$selected_chain_name':"
    select market_choice in "${markets[@]}"; do
        if [ -n "$market_choice" ]; then
            selected_market_name="$market_choice"
            break
        else
            echo "❌ Invalid selection. Please try again."
        fi
    done

    echo "✅ You selected: $selected_market_name on $selected_chain_name"

    local config_result=$(extract_chain_config "$selected_chain_name" "$selected_market_name")
    if [ -n "$config_result" ]; then
        parse_config_vars "$config_result"
        
        export NAMESPACE="$selected_market_name"
        export POWERLOOM_CHAIN="$selected_chain_name"
        export POWERLOOM_RPC_URL="$CHAIN_RPC_URL"
    else
        echo "⚠️  Could not fetch $selected_market_name config from GitHub, exiting..."
        exit 1
    fi
}

# Function to prompt for user credentials
prompt_for_credentials() {
    local env_file="$1"
    read -p "Enter SOURCE_RPC_URL: " source_rpc_url_val
    update_or_append_var "SOURCE_RPC_URL" "$source_rpc_url_val" "$env_file"
    read -p "Enter SIGNER_ACCOUNT_ADDRESS: " signer_account_address_val
    update_or_append_var "SIGNER_ACCOUNT_ADDRESS" "$signer_account_address_val" "$env_file"
    read -s -p "Enter SIGNER_ACCOUNT_PRIVATE_KEY: " signer_account_private_key_val; echo
    update_or_append_var "SIGNER_ACCOUNT_PRIVATE_KEY" "$signer_account_private_key_val" "$env_file"
    read -p "Enter Your SLOT_ID (NFT_ID): " slot_id_val
    update_or_append_var "SLOT_ID" "$slot_id_val" "$env_file"
    read -p "Enter Your TELEGRAM_CHAT_ID (Optional, leave blank to skip.): " telegram_chat_id_val
    update_or_append_var "TELEGRAM_CHAT_ID" "$telegram_chat_id_val" "$env_file"
}

# Function to update all configuration variables in a file
update_common_config() {
    local env_file="$1"
    export FULL_NAMESPACE="${POWERLOOM_CHAIN}-${NAMESPACE}-${SOURCE_CHAIN}"
    export DOCKER_NETWORK_NAME="snapshotter-lite-v2-${FULL_NAMESPACE}"
    
    update_or_append_var "POWERLOOM_CHAIN" "$POWERLOOM_CHAIN" "$env_file"
    update_or_append_var "NAMESPACE" "$NAMESPACE" "$env_file"
    update_or_append_var "SOURCE_CHAIN" "$SOURCE_CHAIN" "$env_file"
    update_or_append_var "POWERLOOM_RPC_URL" "$POWERLOOM_RPC_URL" "$env_file"
    update_or_append_var "PROTOCOL_STATE_CONTRACT" "$PROTOCOL_STATE_CONTRACT" "$env_file"
    update_or_append_var "DATA_MARKET_CONTRACT" "$DATA_MARKET_CONTRACT" "$env_file"
    update_or_append_var "SNAPSHOT_CONFIG_REPO" "$SNAPSHOT_CONFIG_REPO" "$env_file"
    update_or_append_var "SNAPSHOT_CONFIG_REPO_BRANCH" "$SNAPSHOT_CONFIG_REPO_BRANCH" "$env_file"
    update_or_append_var "SNAPSHOT_CONFIG_REPO_COMMIT" "$SNAPSHOT_CONFIG_REPO_COMMIT" "$env_file"
    update_or_append_var "SNAPSHOTTER_COMPUTE_REPO" "$SNAPSHOTTER_COMPUTE_REPO" "$env_file"
    update_or_append_var "SNAPSHOTTER_COMPUTE_REPO_BRANCH" "$SNAPSHOTTER_COMPUTE_REPO_BRANCH" "$env_file"
    update_or_append_var "SNAPSHOTTER_COMPUTE_REPO_COMMIT" "$SNAPSHOTTER_COMPUTE_REPO_COMMIT" "$env_file"
    update_or_append_var "FULL_NAMESPACE" "$FULL_NAMESPACE" "$env_file"
    update_or_append_var "DOCKER_NETWORK_NAME" "$DOCKER_NETWORK_NAME" "$env_file"
    update_or_append_var "CONNECTION_REFRESH_INTERVAL_SEC" "$CONNECTION_REFRESH_INTERVAL_SEC" "$env_file"
    update_or_append_var "TELEGRAM_NOTIFICATION_COOLDOWN" "$TELEGRAM_NOTIFICATION_COOLDOWN" "$env_file"
}

# Function to handle credential updates
handle_credential_updates() {
    if [ "$SKIP_CREDENTIAL_UPDATE" = "true" ]; then return; fi
    if [ "$FILE_WAS_NEWLY_CREATED" = "true" ]; then return; fi

    local current_signer_address=$(grep "^SIGNER_ACCOUNT_ADDRESS=" "$ENV_FILE_PATH" | cut -d'=' -f2- || echo "")
    local current_slot_id=$(grep "^SLOT_ID=" "$ENV_FILE_PATH" | cut -d'=' -f2- || echo "")
    local current_source_rpc_url=$(grep "^SOURCE_RPC_URL=" "$ENV_FILE_PATH" | cut -d'=' -f2- || echo "")

    read -p "🫸 ▶︎  Would you like to update any credentials in $ENV_FILE_PATH? (y/n): " update_env_vars
    if [ "$update_env_vars" = "y" ]; then
        SETUP_COMPLETE=false
        read -p "Enter new SIGNER_ACCOUNT_ADDRESS (current: ${current_signer_address:-\<not set\>}, press enter to skip): " new_signer_account_address
        if [ -n "$new_signer_account_address" ]; then
            read -s -p "Enter new SIGNER_ACCOUNT_PRIVATE_KEY: " new_signer_account_private_key; echo
            update_or_append_var "SIGNER_ACCOUNT_ADDRESS" "$new_signer_account_address" "$ENV_FILE_PATH"
            update_or_append_var "SIGNER_ACCOUNT_PRIVATE_KEY" "$new_signer_account_private_key" "$ENV_FILE_PATH"
        fi
        read -p "Enter new SLOT_ID (current: ${current_slot_id:-\<not set\>}, press enter to skip): " new_slot_id
        if [ -n "$new_slot_id" ]; then update_or_append_var "SLOT_ID" "$new_slot_id" "$ENV_FILE_PATH"; fi
        read -p "Enter new SOURCE_RPC_URL (current: ${current_source_rpc_url:-\<not set\>}, press enter to skip): " new_source_rpc_url
        if [ -n "$new_source_rpc_url" ]; then update_or_append_var "SOURCE_RPC_URL" "$new_source_rpc_url" "$ENV_FILE_PATH"; fi
        read -p "Enter new TELEGRAM_CHAT_ID (press enter to skip): " new_telegram_chat_id
        if [ -n "$new_telegram_chat_id" ]; then update_or_append_var "TELEGRAM_CHAT_ID" "$new_telegram_chat_id" "$ENV_FILE_PATH"; fi
    fi
}

# Function to set default optional variables
set_default_optional_variables() {
    local env_file="$1"
    local optional_vars=(
        "LOCAL_COLLECTOR_PORT:50051"
        "MAX_STREAM_POOL_SIZE:2"
        "STREAM_HEALTH_CHECK_TIMEOUT_MS:5000"
        "STREAM_WRITE_TIMEOUT_MS:5000"
        "MAX_WRITE_RETRIES:3"
        "MAX_CONCURRENT_WRITES:4"
        "TELEGRAM_MESSAGE_THREAD_ID:"
        "GOSSIPSUB_SNAPSHOT_SUBMISSION_PREFIX:/powerloom/snapshot-submissions"
    )
    for var_def in "${optional_vars[@]}"; do
        local var_name="${var_def%:*}"
        local default_value="${var_def#*:}"
        if ! grep -q "^${var_name}=" "$env_file"; then
            echo "🔔 $var_name not found in $env_file, setting to default value ${default_value} and adding to file."
            update_or_append_var "$var_name" "$default_value" "$env_file"
        fi
    done

    # Add DSV-specific configuration for devnet mode
    if [ "$DEVNET_MODE" = "true" ]; then
        echo "🔧 Applying DSV devnet specific configuration..."

        # Set DSV-specific gossipsub and rendezvous point for devnet
        if ! grep -q "^GOSSIPSUB_SNAPSHOT_SUBMISSION_PREFIX=" "$env_file"; then
            update_or_append_var "GOSSIPSUB_SNAPSHOT_SUBMISSION_PREFIX" "/powerloom/dsv-devnet-alpha/snapshot-submissions" "$env_file"
            echo "🔔 GOSSIPSUB_SNAPSHOT_SUBMISSION_PREFIX not found in $env_file, setting to DSV devnet default"
        else
            # Update existing GOSSIPSUB to DSV version for devnet
            sed -i.bak 's|^GOSSIPSUB_SNAPSHOT_SUBMISSION_PREFIX=.*|GOSSIPSUB_SNAPSHOT_SUBMISSION_PREFIX=/powerloom/dsv-devnet-alpha/snapshot-submissions|' "$env_file"
            echo "🔧 Updated GOSSIPSUB_SNAPSHOT_SUBMISSION_PREFIX for DSV devnet mode"
        fi

        if ! grep -q "^RENDEZVOUS_POINT=" "$env_file"; then
            update_or_append_var "RENDEZVOUS_POINT" "powerloom-dsv-devnet-alpha" "$env_file"
            echo "🔔 RENDEZVOUS_POINT not found in $env_file, setting to DSV devnet default"
        else
            # Update existing RENDEZVOUS_POINT to DSV version for devnet
            sed -i.bak 's|^RENDEZVOUS_POINT=.*|RENDEZVOUS_POINT=powerloom-dsv-devnet-alpha|' "$env_file"
            echo "🔧 Updated RENDEZVOUS_POINT for DSV devnet mode"
        fi

        # Configure P2P port for DSV devnet
        if ! grep -q "^LOCAL_COLLECTOR_P2P_PORT=" "$env_file"; then
            update_or_append_var "LOCAL_COLLECTOR_P2P_PORT" "8001" "$env_file"
            echo "🔔 LOCAL_COLLECTOR_P2P_PORT not found in $env_file, setting to DSV devnet default (8001)"
        else
            echo "✅ LOCAL_COLLECTOR_P2P_PORT already configured in $env_file"
        fi

        # Handle P2P private key for shared volume approach
        if ! grep -q "^LOCAL_COLLECTOR_PRIVATE_KEY=" "$env_file"; then
            echo "🔑 LOCAL_COLLECTOR_PRIVATE_KEY will be generated in container after slot ID validation"
            echo "   This ensures keys are only generated for verified snapshotter addresses"
        else
            echo "✅ LOCAL_COLLECTOR_PRIVATE_KEY already configured in $env_file"

            # Extract the existing key and write it to shared volume for immediate availability
            EXISTING_P2P_KEY=$(grep "^LOCAL_COLLECTOR_PRIVATE_KEY=" "$env_file" | cut -d'=' -f2-)
            if [ -n "$EXISTING_P2P_KEY" ]; then
                echo "📝 Writing pre-configured P2P key to shared volume for immediate availability..."

                # Create shared keys directory
                SHARED_KEYS_DIR="./shared-volume"
                mkdir -p "$SHARED_KEYS_DIR"

                # Write private key to shared volume
                echo "$EXISTING_P2P_KEY" > "$SHARED_KEYS_DIR/p2p_private_key"
                chmod 600 "$SHARED_KEYS_DIR/p2p_private_key"

                # Create signal file to indicate key is ready
                echo "Pre-configured P2P key ready" > "$SHARED_KEYS_DIR/p2p_ready"
                chmod 644 "$SHARED_KEYS_DIR/p2p_ready"

                echo "✅ Pre-configured P2P key written to shared volume: $SHARED_KEYS_DIR/p2p_private_key"
                echo "🔗 Local collector can start immediately with pre-configured key"
            else
                echo "⚠️  Found LOCAL_COLLECTOR_PRIVATE_KEY in env file but value is empty"
            fi
        fi

        # Configure optional PUBLIC_IP for DSV devnet (helps with P2P discovery)
        if ! grep -q "^PUBLIC_IP=" "$env_file"; then
            echo "🌐 PUBLIC_IP is optional for P2P discovery - leaving unset"
            echo "   To set manually: Add PUBLIC_IP=<your_public_ip> to $env_file"
        else
            echo "✅ PUBLIC_IP already configured in $env_file"
        fi

        # Validate bootstrap node configuration for DSV devnet
        if grep -q "^BOOTSTRAP_NODE_ADDR=" "$env_file"; then
            BOOTSTRAP_ADDR=$(grep "^BOOTSTRAP_NODE_ADDR=" "$env_file" | cut -d'=' -f2)
            if [ -n "$BOOTSTRAP_ADDR" ]; then
                echo "✅ BOOTSTRAP_NODE_ADDR configured: $BOOTSTRAP_ADDR"
            else
                echo "⚠️  BOOTSTRAP_NODE_ADDR is empty, P2P connectivity may be affected"
            fi
        else
            echo "⚠️  BOOTSTRAP_NODE_ADDR not found in $env_file"
            echo "   This should have been auto-fetched from curated-datamarkets"
            echo "   Manual setup may be required: Add BOOTSTRAP_NODE_ADDR=<multiaddr> to $env_file"
        fi

        # Remove backup files if they exist
        rm -f "$env_file.bak"

        echo "🎉 DSV devnet P2P configuration completed!"
    fi
}

# Main execution flow
main() {
    parse_arguments "$@"
    if [ "$DOCKER_MODE" != "true" ] && ! docker info >/dev/null 2>&1; then
        echo "❌ Docker daemon is not running"; exit 1; fi

    initialize_default_config

    if [ "$OVERRIDE_DEFAULTS_SCRIPT_FLAG" = "true" ]; then
        echo "OVERRIDE"
        # This path is not fully implemented for interactive override based on new structure
    else
        select_market_and_configure "$DEVNET_MODE"
        
        export FULL_NAMESPACE="${POWERLOOM_CHAIN}-${NAMESPACE}-${SOURCE_CHAIN}"
        ENV_FILE_PATH=".env-${FULL_NAMESPACE}"

        if [ -f "$ENV_FILE_PATH" ]; then
            echo "🟢 Found existing environment file: $ENV_FILE_PATH"
            echo "🔧 Checking for and fixing known formatting issues in $ENV_FILE_PATH..."
            # Fix for previous bug that added spaces around '='
            sed -i.bak 's/ *= */=/g' "$ENV_FILE_PATH"
            # Fix for previous bug that may have created lines starting with '='
            sed -i.bak '/^=/d' "$ENV_FILE_PATH"

            echo "🔔 Updating file with latest configuration from selected market."
            # Source existing file to not lose credentials
            source "$ENV_FILE_PATH"
            update_common_config "$ENV_FILE_PATH"
            FILE_WAS_NEWLY_CREATED=false
        else
            echo "🟡 $ENV_FILE_PATH file not found, creating one..."
            cp env.example "$ENV_FILE_PATH"
            CLEANUP_ENV_FILE_ON_ABORT=true
            TARGET_ENV_FILE_FOR_CLEANUP="$ENV_FILE_PATH"

            export CONNECTION_REFRESH_INTERVAL_SEC="${DEFAULT_CONNECTION_REFRESH_INTERVAL_SEC}"
            export TELEGRAM_NOTIFICATION_COOLDOWN="${DEFAULT_TELEGRAM_NOTIFICATION_COOLDOWN}"

            update_common_config "$ENV_FILE_PATH"
            prompt_for_credentials "$ENV_FILE_PATH"
            FILE_WAS_NEWLY_CREATED=true
            update_or_append_var "OVERRIDE_DEFAULTS" "false" "$ENV_FILE_PATH"
            echo "🟢 $ENV_FILE_PATH file created successfully."
        fi
    fi

    handle_credential_updates
    
    if [ ! -f "$ENV_FILE_PATH" ]; then echo "❌ Env file not found."; exit 1; fi

    source "$ENV_FILE_PATH"
    set_default_optional_variables "$ENV_FILE_PATH"
    
    SETUP_COMPLETE=true
    local required_vars=("POWERLOOM_RPC_URL" "SOURCE_RPC_URL" "SIGNER_ACCOUNT_ADDRESS" "SIGNER_ACCOUNT_PRIVATE_KEY" "SLOT_ID" "DATA_MARKET_CONTRACT" "PROTOCOL_STATE_CONTRACT" "SNAPSHOT_CONFIG_REPO" "SNAPSHOT_CONFIG_REPO_BRANCH" "SNAPSHOT_CONFIG_REPO_COMMIT" "SNAPSHOTTER_COMPUTE_REPO" "SNAPSHOTTER_COMPUTE_REPO_BRANCH" "SNAPSHOTTER_COMPUTE_REPO_COMMIT" "FULL_NAMESPACE")
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo "❌ $var not found after configuration, please set this in your $ENV_FILE_PATH!"
            SETUP_COMPLETE=false
        fi
    done

    if [ "$SETUP_COMPLETE" = true ]; then
        echo "✅ Configuration complete. Environment file ready at $ENV_FILE_PATH"
        if [ -n "$RESULT_FILE" ]; then echo "$ENV_FILE_PATH" > "$RESULT_FILE"; fi
    else
        echo "❌ Configuration incomplete."; exit 1;
    fi
}

main "$@"