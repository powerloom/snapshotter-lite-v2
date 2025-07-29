#!/bin/bash

# Initial variable declarations
DOCKER_NETWORK_PRUNE=false
SETUP_COMPLETE=true
DATA_MARKET_CONTRACT_NUMBER=""
SKIP_CREDENTIAL_UPDATE=false
NO_COLLECTOR=false
OVERRIDE_DEFAULTS_SCRIPT_FLAG=false
DEVNET_MODE=false

# --- Define Top-Level Fixed Defaults ---
DEFAULT_POWERLOOM_CHAIN="mainnet"
DEFAULT_SOURCE_CHAIN="ETH"
DEFAULT_NAMESPACE="UNISWAPV2"
DEFAULT_POWERLOOM_RPC_URL="https://rpc-v2.powerloom.network"
DEFAULT_PROTOCOL_STATE_CONTRACT="0x000AA7d3a6a2556496f363B59e56D9aA1881548F"
DEFAULT_DATA_MARKET_CONTRACT="0x21cb57C1f2352ad215a463DD867b838749CD3b8f"
DEFAULT_SNAPSHOT_CONFIG_REPO_BRANCH="eth_uniswapv2-lite_v2"
DEFAULT_SNAPSHOTTER_COMPUTE_REPO_BRANCH="eth_uniswapv2_lite_v2"
DEFAULT_CONNECTION_REFRESH_INTERVAL_SEC=60
DEFAULT_TELEGRAM_NOTIFICATION_COOLDOWN=300

# --- Define Top-Level Fixed Defaults for Devnet ---
DEFAULT_DEVNET_POWERLOOM_CHAIN="devnet"
DEFAULT_DEVNET_SOURCE_CHAIN="ETH"
DEFAULT_DEVNET_NAMESPACE="UNISWAPV2"
DEFAULT_DEVNET_POWERLOOM_RPC_URL="https://rpc-devnet.powerloom.dev"
DEFAULT_DEVNET_PROTOCOL_STATE_CONTRACT="0x3B5A0FB70ef68B5dd677C7d614dFB89961f97401"
DEFAULT_DEVNET_SNAPSHOT_CONFIG_REPO_BRANCH="eth_uniswapv2-lite_v2"
DEFAULT_DEVNET_SNAPSHOTTER_COMPUTE_REPO_BRANCH="eth_uniswapv2_lite_v2"
DEFAULT_DEVNET_CONNECTION_REFRESH_INTERVAL_SEC=60
DEFAULT_DEVNET_TELEGRAM_NOTIFICATION_COOLDOWN=300

# --- Initialize Working Configuration Variables from Fixed Defaults ---
POWERLOOM_CHAIN="$DEFAULT_POWERLOOM_CHAIN"
SOURCE_CHAIN="$DEFAULT_SOURCE_CHAIN"
NAMESPACE="$DEFAULT_NAMESPACE"
POWERLOOM_RPC_URL="$DEFAULT_POWERLOOM_RPC_URL"
PROTOCOL_STATE_CONTRACT="$DEFAULT_PROTOCOL_STATE_CONTRACT"
DATA_MARKET_CONTRACT="$DEFAULT_DATA_MARKET_CONTRACT"
SNAPSHOT_CONFIG_REPO_BRANCH="$DEFAULT_SNAPSHOT_CONFIG_REPO_BRANCH"
SNAPSHOTTER_COMPUTE_REPO_BRANCH="$DEFAULT_SNAPSHOTTER_COMPUTE_REPO_BRANCH"
CONNECTION_REFRESH_INTERVAL_SEC="$DEFAULT_CONNECTION_REFRESH_INTERVAL_SEC"
TELEGRAM_NOTIFICATION_COOLDOWN="$DEFAULT_TELEGRAM_NOTIFICATION_COOLDOWN"

# --- Global Variables ---
ENV_FILE_PATH=""
FILE_CONTAINS_OVERRIDES="false"
SELECTED_ENV_FILE=""
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
        local existing_var_value=$(grep "^${var_name}=" "$target_file" | cut -d'=' -f2)
        if [[ "$existing_var_value" == "<"* ]]; then
            #echo "🔍 Possible first time setup. Existing value for $var_name starts with <, replacing with default value: $var_value"
            sed -i".backup" "s#^${var_name}=.*#${var_name}=${var_value}#" "$target_file"
            return
        fi
        if [ "$OVERRIDE_DEFAULTS_SCRIPT_FLAG" != "true" ] && \
           ([ "$var_name" == "CONNECTION_REFRESH_INTERVAL_SEC" ] || \
            [ "$var_name" == "TELEGRAM_NOTIFICATION_COOLDOWN" ]); then
            local masked_existing=$(mask_sensitive_value "$var_name" "$existing_var_value")
            echo "🔍 Skipping update for $var_name, using existing value: $masked_existing"
        else
            if [ "$var_value" != "$existing_var_value" ]; then
                local masked_new=$(mask_sensitive_value "$var_name" "$var_value")
                local masked_existing=$(mask_sensitive_value "$var_name" "$existing_var_value")
                echo "🔍 Overriding $var_name in $target_file with value: $masked_new (existing value: $masked_existing)"
                local sed_safe_var_value=$(echo "$var_value" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/#/\\#/g')
                sed -i".backup" "s#^${var_name}=.*#${var_name}=${sed_safe_var_value}#" "$target_file"
            # else
            #     local masked_value=$(mask_sensitive_value "$var_name" "$var_value")
            #     echo "🔍 No change for $var_name, existing value matches new value: $masked_value"
            fi
        fi
    else
        if [ -s "$target_file" ] && [ "$(tail -c 1 "$target_file" | wc -l)" -eq 0 ]; then
            echo "" >> "$target_file"
        fi
        local masked_value=$(mask_sensitive_value "$var_name" "$var_value")
        echo "🔍 Adding new variable $var_name to $target_file with value: $masked_value"
        echo "${var_name}=${var_value}" >> "$target_file"
    fi
}

# Function to detect and select environment files
detect_and_select_env_file() {
    # Filter for devnet files if in devnet mode
    if [ "$DEVNET_MODE" = "true" ]; then
        return
    fi
    #ignore .env-devnet-* files
    local existing_env_files=($(find . -maxdepth 1 -name ".env-*" -type f -not -name ".env-devnet-*"))
    local num_existing_env_files=${#existing_env_files[@]}
    
    if [ "$num_existing_env_files" -eq 1 ]; then
        SELECTED_ENV_FILE="${existing_env_files[0]}"
        echo "ℹ️ Auto-selected existing environment file: $SELECTED_ENV_FILE"
    elif [ "$num_existing_env_files" -gt 1 ]; then
        echo "Found multiple .env-* files. Please choose which one to use:"
        for i in "${!existing_env_files[@]}"; do
            echo "$((i+1))) ${existing_env_files[$i]}"
        done
        read -p "Enter number (1-$num_existing_env_files): " file_choice
        if [[ "$file_choice" =~ ^[0-9]+$ ]] && [ "$file_choice" -ge 1 ] && [ "$file_choice" -le "$num_existing_env_files" ]; then
            SELECTED_ENV_FILE="${existing_env_files[$((file_choice-1))]}"
            echo "ℹ️ You selected: $SELECTED_ENV_FILE"
        else
            echo "❌ Invalid selection. Exiting."
            exit 1
        fi
    fi

    if [ -n "$SELECTED_ENV_FILE" ]; then
        ENV_FILE_PATH="$SELECTED_ENV_FILE"
        echo "🟢 Using environment file: $ENV_FILE_PATH"
        FILE_CONTAINS_OVERRIDES=$(grep "^OVERRIDE_DEFAULTS=" "$ENV_FILE_PATH" | cut -d'=' -f2 || echo "false")
    fi
}

# Function to parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --docker-network-prune)
                DOCKER_NETWORK_PRUNE=true
                shift
                ;;
            --data-market-contract-number)
                DATA_MARKET_CONTRACT_NUMBER=$2
                shift 2
                ;;
            --skip-credential-update)
                SKIP_CREDENTIAL_UPDATE=true
                shift
                ;;
            --no-collector)
                NO_COLLECTOR=true
                shift
                ;;
            --override)
                OVERRIDE_DEFAULTS_SCRIPT_FLAG=true
                shift
                ;;
            --devnet)
                DEVNET_MODE=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
}

# Function to get data market configuration
get_data_market_config() {
    local choice="$1"
    local is_devnet="${2:-false}"
    
    # Define contract addresses
    local MAINNET_AAVEV3_CONTRACT="0x0000000000000000000000000000000000000000"
    local MAINNET_UNISWAPV2_CONTRACT="0x21cb57C1f2352ad215a463DD867b838749CD3b8f"
    local DEVNET_AAVEV3_CONTRACT="0x4229Ad271d8b11f2AdBDe77099752a534470876b"
    local DEVNET_UNISWAPV2_CONTRACT="0x8C3fDC3A281BbB8231c9c92712fE670eFA655e5f"
    
    case $choice in
        "1")
            if [ "$is_devnet" = "true" ]; then
                echo "Aave V3 selected for devnet"
                export DATA_MARKET_CONTRACT="$DEVNET_AAVEV3_CONTRACT"
            else
                echo "Aave V3 selected"
                export DATA_MARKET_CONTRACT="$MAINNET_AAVEV3_CONTRACT"
            fi
            export SNAPSHOT_CONFIG_REPO_BRANCH="eth_aavev3_lite_v2"
            export SNAPSHOTTER_COMPUTE_REPO_BRANCH="eth_aavev3_lite"
            export NAMESPACE="AAVEV3"
            ;;
        "2")
            if [ "$is_devnet" = "true" ]; then
                echo "Uniswap V2 selected for devnet"
                export DATA_MARKET_CONTRACT="$DEVNET_UNISWAPV2_CONTRACT"
            else
                echo "Uniswap V2 selected"
                export DATA_MARKET_CONTRACT="$MAINNET_UNISWAPV2_CONTRACT"
            fi
            export SNAPSHOT_CONFIG_REPO_BRANCH="eth_uniswapv2-lite_v2"
            export SNAPSHOTTER_COMPUTE_REPO_BRANCH="eth_uniswapv2_lite_v2"
            export NAMESPACE="UNISWAPV2"
            ;;
        *)
            echo "❌ Invalid data market choice: $choice"
            exit 1
            ;;
    esac
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

# Function to update common configuration variables
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
    update_or_append_var "SNAPSHOT_CONFIG_REPO_BRANCH" "$SNAPSHOT_CONFIG_REPO_BRANCH" "$env_file"
    update_or_append_var "SNAPSHOTTER_COMPUTE_REPO_BRANCH" "$SNAPSHOTTER_COMPUTE_REPO_BRANCH" "$env_file"
    update_or_append_var "FULL_NAMESPACE" "$FULL_NAMESPACE" "$env_file"
    update_or_append_var "DOCKER_NETWORK_NAME" "$DOCKER_NETWORK_NAME" "$env_file"
    update_or_append_var "CONNECTION_REFRESH_INTERVAL_SEC" "$CONNECTION_REFRESH_INTERVAL_SEC" "$env_file"
    update_or_append_var "TELEGRAM_NOTIFICATION_COOLDOWN" "$TELEGRAM_NOTIFICATION_COOLDOWN" "$env_file"
}

# Function to handle override mode configuration
handle_override_mode() {
    SETUP_COMPLETE=false
    echo "🔧 Custom configuration mode enabled via --override flag."
    
    # Get Powerloom chain selection
    echo "Select POWERLOOM_CHAIN:"
    echo "1. mainnet (default)"
    echo "2. devnet"
    read -p "Enter choice (1-2) [default: 1]: " powerloom_chain_choice_input
    local powerloom_chain_choice=${powerloom_chain_choice_input:-1}

    while ! [[ "$powerloom_chain_choice" =~ ^[1-2]$ ]]; do
        read -p "Invalid input. Enter choice (1-2): " powerloom_chain_choice
    done

    case $powerloom_chain_choice in
        1) export POWERLOOM_CHAIN="mainnet" ;;
        2) export POWERLOOM_CHAIN="devnet" ;;
    esac
    echo "Selected POWERLOOM_CHAIN: $POWERLOOM_CHAIN"

    # Get other configuration values
    read -p "Enter NAMESPACE (e.g., UNISWAPV2, AAVEV3, or custom name) [default: $DEFAULT_NAMESPACE]: " namespace_input
    export NAMESPACE=${namespace_input:-$DEFAULT_NAMESPACE}
    echo "Selected NAMESPACE: $NAMESPACE"

    read -p "Enter SOURCE_CHAIN (e.g., ETH) [default: $DEFAULT_SOURCE_CHAIN]: " source_chain_input
    export SOURCE_CHAIN=${source_chain_input:-$DEFAULT_SOURCE_CHAIN}
    echo "Selected SOURCE_CHAIN: $SOURCE_CHAIN"

    read -p "Enter POWERLOOM_RPC_URL [default: $DEFAULT_POWERLOOM_RPC_URL]: " powerloom_rpc_url_input
    export POWERLOOM_RPC_URL=${powerloom_rpc_url_input:-$DEFAULT_POWERLOOM_RPC_URL}

    read -p "Enter PROTOCOL_STATE_CONTRACT [default: $DEFAULT_PROTOCOL_STATE_CONTRACT]: " protocol_state_contract_input
    export PROTOCOL_STATE_CONTRACT=${protocol_state_contract_input:-$DEFAULT_PROTOCOL_STATE_CONTRACT}

    read -p "Enter DATA_MARKET_CONTRACT: " data_market_contract_input
    while [ -z "$data_market_contract_input" ]; do
        read -p "DATA_MARKET_CONTRACT cannot be empty. Enter DATA_MARKET_CONTRACT: " data_market_contract_input
    done
    export DATA_MARKET_CONTRACT="$data_market_contract_input"

    # Handle repository branches
    read -p "Would you like to specify custom snapshot configuration and compute repository branches? (y/n) [default: n]: " override_branches_choice
    override_branches_choice=${override_branches_choice:-n}

    if [[ "$override_branches_choice" =~ ^[Yy]$ ]]; then
        read -p "Enter SNAPSHOT_CONFIG_REPO_BRANCH [default: $DEFAULT_SNAPSHOT_CONFIG_REPO_BRANCH]: " snapshot_config_repo_branch_input
        export SNAPSHOT_CONFIG_REPO_BRANCH=${snapshot_config_repo_branch_input:-$DEFAULT_SNAPSHOT_CONFIG_REPO_BRANCH}
        read -p "Enter SNAPSHOTTER_COMPUTE_REPO_BRANCH [default: $DEFAULT_SNAPSHOTTER_COMPUTE_REPO_BRANCH]: " snapshotter_compute_repo_branch_input
        export SNAPSHOTTER_COMPUTE_REPO_BRANCH=${snapshotter_compute_repo_branch_input:-$DEFAULT_SNAPSHOTTER_COMPUTE_REPO_BRANCH}
    else
        export SNAPSHOT_CONFIG_REPO_BRANCH="$DEFAULT_SNAPSHOT_CONFIG_REPO_BRANCH"
        export SNAPSHOTTER_COMPUTE_REPO_BRANCH="$DEFAULT_SNAPSHOTTER_COMPUTE_REPO_BRANCH"
    fi
    echo "Selected SNAPSHOT_CONFIG_REPO_BRANCH: $SNAPSHOT_CONFIG_REPO_BRANCH"
    echo "Selected SNAPSHOTTER_COMPUTE_REPO_BRANCH: $SNAPSHOTTER_COMPUTE_REPO_BRANCH"

    # Determine target environment file
    export FULL_NAMESPACE="${POWERLOOM_CHAIN}-${NAMESPACE}-${SOURCE_CHAIN}"
    local target_env_file_for_overrides=".env-${FULL_NAMESPACE}"

    if [ -n "$ENV_FILE_PATH" ] && [ "$ENV_FILE_PATH" != "$target_env_file_for_overrides" ]; then
        echo "ℹ️ Configuration values resulted in a new target .env file: $target_env_file_for_overrides"
        echo "Previously selected file was: $ENV_FILE_PATH (if any)."
    elif [ -z "$ENV_FILE_PATH" ]; then
         echo "ℹ️ Creating new configuration based on overrides: $target_env_file_for_overrides"
    fi
    ENV_FILE_PATH="$target_env_file_for_overrides"

    # Create or update environment file
    if [ ! -f "$ENV_FILE_PATH" ]; then
        echo "🟡 $ENV_FILE_PATH file not found, creating one based on overrides..."
        cp env.example "$ENV_FILE_PATH"
        CLEANUP_ENV_FILE_ON_ABORT=true
        TARGET_ENV_FILE_FOR_CLEANUP="$ENV_FILE_PATH"
        prompt_for_credentials "$ENV_FILE_PATH"
        FILE_WAS_NEWLY_CREATED=true
    else
        echo "🟢 $ENV_FILE_PATH found. Will update it with override values."
        
        # Read existing values for CONNECTION_REFRESH_INTERVAL_SEC and TELEGRAM_NOTIFICATION_COOLDOWN
        local existing_connection_refresh=$(grep "^CONNECTION_REFRESH_INTERVAL_SEC=" "$ENV_FILE_PATH" | cut -d'=' -f2 || echo "")
        local existing_telegram_cooldown=$(grep "^TELEGRAM_NOTIFICATION_COOLDOWN=" "$ENV_FILE_PATH" | cut -d'=' -f2 || echo "")
        
        if [ -n "$existing_connection_refresh" ]; then
            export CONNECTION_REFRESH_INTERVAL_SEC="$existing_connection_refresh"
            echo "🔍 Using existing CONNECTION_REFRESH_INTERVAL_SEC: $existing_connection_refresh"
        fi
        
        if [ -n "$existing_telegram_cooldown" ]; then
            export TELEGRAM_NOTIFICATION_COOLDOWN="$existing_telegram_cooldown"
            echo "🔍 Using existing TELEGRAM_NOTIFICATION_COOLDOWN: $existing_telegram_cooldown"
        fi
    fi
 
    update_common_config "$ENV_FILE_PATH"
    update_or_append_var "OVERRIDE_DEFAULTS" "true" "$ENV_FILE_PATH"
    echo "✅ $ENV_FILE_PATH configured with overrides."
}

# Function to handle devnet mode configuration
handle_devnet_mode() {
    SETUP_COMPLETE=false
    echo "🔧 Devnet mode enabled via --devnet flag."
    
    # Use devnet defaults
    POWERLOOM_CHAIN="$DEFAULT_DEVNET_POWERLOOM_CHAIN"
    SOURCE_CHAIN="$DEFAULT_DEVNET_SOURCE_CHAIN"
    NAMESPACE="$DEFAULT_DEVNET_NAMESPACE"
    POWERLOOM_RPC_URL="$DEFAULT_DEVNET_POWERLOOM_RPC_URL"
    PROTOCOL_STATE_CONTRACT="$DEFAULT_DEVNET_PROTOCOL_STATE_CONTRACT"
    SNAPSHOT_CONFIG_REPO_BRANCH="$DEFAULT_DEVNET_SNAPSHOT_CONFIG_REPO_BRANCH"
    SNAPSHOTTER_COMPUTE_REPO_BRANCH="$DEFAULT_DEVNET_SNAPSHOTTER_COMPUTE_REPO_BRANCH"
    CONNECTION_REFRESH_INTERVAL_SEC="$DEFAULT_DEVNET_CONNECTION_REFRESH_INTERVAL_SEC"
    TELEGRAM_NOTIFICATION_COOLDOWN="$DEFAULT_DEVNET_TELEGRAM_NOTIFICATION_COOLDOWN"
    
    # Use data market contract number if specified, otherwise default to Uniswap V2
    if [ -n "$DATA_MARKET_CONTRACT_NUMBER" ]; then
        get_data_market_config "$DATA_MARKET_CONTRACT_NUMBER" "true"
    else
        echo "🔍 Select a data market contract: "
        echo "1. Aave V3"
        echo "2. Uniswap V2 (default)"
        read DATA_MARKET_CONTRACT_CHOICE
        
        # Set default to Uniswap V2 if empty or invalid input
        if [ -z "$DATA_MARKET_CONTRACT_CHOICE" ] || ! [[ "$DATA_MARKET_CONTRACT_CHOICE" =~ ^[12]$ ]]; then
            DATA_MARKET_CONTRACT_CHOICE="2"
            echo "Using default: Uniswap V2"
        fi
        get_data_market_config "$DATA_MARKET_CONTRACT_CHOICE" "true"
    fi
    
    # Determine target environment file
    export FULL_NAMESPACE="${POWERLOOM_CHAIN}-${NAMESPACE}-${SOURCE_CHAIN}"
    local target_env_file_for_devnet=".env-${FULL_NAMESPACE}"
    
    if [ -n "$ENV_FILE_PATH" ] && [ "$ENV_FILE_PATH" != "$target_env_file_for_devnet" ]; then
        echo "ℹ️ Switching to devnet configuration: $target_env_file_for_devnet"
        echo "Previously selected file was: $ENV_FILE_PATH"
    elif [ -z "$ENV_FILE_PATH" ]; then
        echo "ℹ️ Creating new devnet configuration: $target_env_file_for_devnet"
    fi
    ENV_FILE_PATH="$target_env_file_for_devnet"
    
    # Create or update environment file
    if [ ! -f "$ENV_FILE_PATH" ]; then
        echo "🟡 $ENV_FILE_PATH file not found, creating one for devnet..."
        cp env.example "$ENV_FILE_PATH"
        CLEANUP_ENV_FILE_ON_ABORT=true
        TARGET_ENV_FILE_FOR_CLEANUP="$ENV_FILE_PATH"
        prompt_for_credentials "$ENV_FILE_PATH"
        FILE_WAS_NEWLY_CREATED=true
    else
        echo "🟢 $ENV_FILE_PATH found. Will update it with devnet values."
    fi
    
    update_common_config "$ENV_FILE_PATH"
    update_or_append_var "OVERRIDE_DEFAULTS" "true" "$ENV_FILE_PATH"
    echo "✅ $ENV_FILE_PATH configured for devnet."
}

# Function to handle existing environment file
handle_existing_env_file() {
    echo "🟢 Operating on selected environment file: $ENV_FILE_PATH"
    
    if [ "$FILE_CONTAINS_OVERRIDES" = "true" ]; then
        echo "🔔 $ENV_FILE_PATH has OVERRIDE_DEFAULTS=true. Preserving existing overrides."
        update_or_append_var "OVERRIDE_DEFAULTS" "true" "$ENV_FILE_PATH"
    else
        echo "🔔 $ENV_FILE_PATH has OVERRIDE_DEFAULTS=false (or not set). Applying standard script defaults/updates."
        
        # Handle data market contract number if specified
        if [ -n "$DATA_MARKET_CONTRACT_NUMBER" ] && [ "$DATA_MARKET_CONTRACT_NUMBER" = "2" ]; then
            local uniswap_v2_dm_contract="0x21cb57C1f2352ad215a463DD867b838749CD3b8f"
            local current_dm_contract_in_file=$(grep "^DATA_MARKET_CONTRACT=" "$ENV_FILE_PATH" | cut -d'=' -f2- || echo "")
            if [ "$current_dm_contract_in_file" != "$uniswap_v2_dm_contract" ]; then
                echo "🔔 Ensuring DATA_MARKET_CONTRACT is Uniswap V2 in $ENV_FILE_PATH due to contract number selection."
                update_or_append_var "DATA_MARKET_CONTRACT" "$uniswap_v2_dm_contract" "$ENV_FILE_PATH"
            fi
            export DATA_MARKET_CONTRACT="$uniswap_v2_dm_contract"
        fi
    fi

    update_common_config "$ENV_FILE_PATH"
}

# Function to create new default environment file
create_new_default_env_file() {
    echo "🔧 No .env file specified or found, and --override not used. Proceeding to create a new default configuration."
    
    SETUP_COMPLETE=false

    # Set default to Uniswap V2 if no flag provided
    if [ -z "$DATA_MARKET_CONTRACT_NUMBER" ]; then
        export DATA_MARKET_CONTRACT_NUMBER="2"
    fi

    # Data market selection
    if [ -n "$DATA_MARKET_CONTRACT_NUMBER" ]; then
        DATA_MARKET_CONTRACT_CHOICE="$DATA_MARKET_CONTRACT_NUMBER"
    else
        echo "🔍 Select a data market contract: "
        echo "1. Aave V3"
        echo "2. Uniswap V2 (default)"
        read DATA_MARKET_CONTRACT_CHOICE
        
        # Set default to Uniswap V2 if empty or invalid input
        if [ -z "$DATA_MARKET_CONTRACT_CHOICE" ] || ! [[ "$DATA_MARKET_CONTRACT_CHOICE" =~ ^[12]$ ]]; then
            DATA_MARKET_CONTRACT_CHOICE="2"
            echo "Using default: Uniswap V2"
        fi
    fi

    get_data_market_config "$DATA_MARKET_CONTRACT_CHOICE"

    # Export remaining defaults
    export POWERLOOM_CHAIN
    export SOURCE_CHAIN
    export POWERLOOM_RPC_URL
    export PROTOCOL_STATE_CONTRACT
    export CONNECTION_REFRESH_INTERVAL_SEC
    export TELEGRAM_NOTIFICATION_COOLDOWN

    export FULL_NAMESPACE="${POWERLOOM_CHAIN}-${NAMESPACE}-${SOURCE_CHAIN}"
    ENV_FILE_PATH=".env-${FULL_NAMESPACE}"

    echo "🟡 $ENV_FILE_PATH file not found, creating one..."
    cp env.example "$ENV_FILE_PATH"
    CLEANUP_ENV_FILE_ON_ABORT=true
    TARGET_ENV_FILE_FOR_CLEANUP="$ENV_FILE_PATH"

    update_common_config "$ENV_FILE_PATH"
    prompt_for_credentials "$ENV_FILE_PATH"
    FILE_WAS_NEWLY_CREATED=true
    
    update_or_append_var "OVERRIDE_DEFAULTS" "false" "$ENV_FILE_PATH"
    echo "🟢 $ENV_FILE_PATH file created successfully."
}

# Function to handle credential updates
handle_credential_updates() {
    if [ "$SKIP_CREDENTIAL_UPDATE" = "true" ]; then
        echo "🔔 Skipping credential update prompts due to --skip-credential-update flag"
        return
    fi
    
    if [ "$FILE_WAS_NEWLY_CREATED" = "true" ]; then
        echo "ℹ️ Skipping update prompt as $ENV_FILE_PATH was just created and configured."
        return
    fi

    if [ -f "$ENV_FILE_PATH" ]; then
        source "$ENV_FILE_PATH"
    fi

    read -p "🫸 ▶︎  Would you like to update any of the environment variables in $ENV_FILE_PATH? (y/n): " update_env_vars
    if [ "$update_env_vars" = "y" ]; then
        SETUP_COMPLETE=false
        
        read -p "Enter new SIGNER_ACCOUNT_ADDRESS (current: ${SIGNER_ACCOUNT_ADDRESS:-<not set>}, press enter to skip): " new_signer_account_address
        if [ -n "$new_signer_account_address" ]; then
            read -s -p "Enter new SIGNER_ACCOUNT_PRIVATE_KEY: " new_signer_account_private_key; echo
            update_or_append_var "SIGNER_ACCOUNT_ADDRESS" "$new_signer_account_address" "$ENV_FILE_PATH"
            update_or_append_var "SIGNER_ACCOUNT_PRIVATE_KEY" "$new_signer_account_private_key" "$ENV_FILE_PATH"
            export SIGNER_ACCOUNT_ADDRESS="$new_signer_account_address"
            export SIGNER_ACCOUNT_PRIVATE_KEY="$new_signer_account_private_key"
        fi

        read -p "Enter new SLOT_ID (NFT_ID) (current: ${SLOT_ID:-<not set>}, press enter to skip): " new_slot_id
        if [ -n "$new_slot_id" ]; then
            update_or_append_var "SLOT_ID" "$new_slot_id" "$ENV_FILE_PATH"
            export SLOT_ID="$new_slot_id"
        fi

        read -p "Enter new SOURCE_RPC_URL (current: ${SOURCE_RPC_URL:-<not set>}, press enter to skip): " new_source_rpc_url
        if [ -n "$new_source_rpc_url" ]; then
            update_or_append_var "SOURCE_RPC_URL" "$new_source_rpc_url" "$ENV_FILE_PATH"
            export SOURCE_RPC_URL="$new_source_rpc_url"
        fi
        echo "Feel free to ask for help in our Discord: https://discord.gg/powerloom if you need assistance. DO NOT SHARE YOUR PRIVATE KEYS."
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
    )
    
    for var_def in "${optional_vars[@]}"; do
        local var_name="${var_def%:*}"
        local default_value="${var_def#*:}"
        
        if [ -z "${!var_name}" ]; then
            export "$var_name"="$default_value"
            echo "🔔 $var_name not found in $env_file, setting to default value ${!var_name} and adding to file."
            update_or_append_var "$var_name" "${!var_name}" "$env_file"
        fi
    done
}

# Function to validate environment configuration
validate_environment() {
    SETUP_COMPLETE=true
    
    local required_vars=(
        "POWERLOOM_RPC_URL"
        "SOURCE_RPC_URL"
        "SIGNER_ACCOUNT_ADDRESS"
        "SIGNER_ACCOUNT_PRIVATE_KEY"
        "SLOT_ID"
        "DATA_MARKET_CONTRACT"
        "PROTOCOL_STATE_CONTRACT"
        "SNAPSHOT_CONFIG_REPO_BRANCH"
        "SNAPSHOTTER_COMPUTE_REPO_BRANCH"
        "FULL_NAMESPACE"
    )
    
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo "❌ $var not found after configuration, please set this in your $ENV_FILE_PATH!"
            SETUP_COMPLETE=false
        fi
    done
}

# Main execution flow
main() {
    # Check Docker daemon
    if ! docker info >/dev/null 2>&1; then
        echo "❌ Docker daemon is not running"
        exit 1
    fi

    # Parse command line arguments
    parse_arguments "$@"

    if [ "$OVERRIDE_DEFAULTS_SCRIPT_FLAG" = "true" ]; then
        echo "🔔 OVERRIDE_DEFAULTS_SCRIPT_FLAG is true"
        handle_override_mode
    else
        detect_and_select_env_file

        if [ "$DEVNET_MODE" = "true" ]; then
            handle_devnet_mode
        elif [ -n "$ENV_FILE_PATH" ]; then
            handle_existing_env_file
        else
            create_new_default_env_file
        fi
    fi

    # Handle credential updates
    handle_credential_updates
    
    # Final source and setup
    if [ ! -f "$ENV_FILE_PATH" ]; then
        echo "❌ Error: Environment file $ENV_FILE_PATH not found before final sourcing. This should not happen. Exiting."
        exit 1
    fi
    source "$ENV_FILE_PATH"

    # Set default optional variables
    set_default_optional_variables "$ENV_FILE_PATH"
    
    # Validate environment
    validate_environment
    
    # Export NO_COLLECTOR for use in deploy-services.sh
    export NO_COLLECTOR

    if [ "$SETUP_COMPLETE" = true ]; then
        echo "✅ Configuration complete. Environment file ready at $ENV_FILE_PATH"
    else
        echo "❌ Configuration incomplete or encountered errors. Please review messages and $ENV_FILE_PATH."
        exit 1
    fi
}

# Run main function with all arguments
main "$@"
