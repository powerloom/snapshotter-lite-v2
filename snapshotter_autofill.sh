#!/bin/bash


echo 'Snapshotter node: populating setting from environment values...';

if [ -z "$SOURCE_RPC_URL" ]; then
    echo "RPC URL not found, please set this in your .env!";
    exit 1;
fi

if [ -z "$SIGNER_ACCOUNT_ADDRESS" ]; then
    echo "SIGNER_ACCOUNT_ADDRESS not found, please set this in your .env!";
    exit 1;
fi

if [ -z "$POWERLOOM_RPC_URL" ]; then
    echo "POWERLOOM_RPC_URL not found, please set this in your .env!";
    exit 1;
fi

if [ -z "$SLOT_ID" ]; then
    echo "SLOT_ID not found, please set this in your .env!";
    exit 1;
fi

if [ -z "$PROTOCOL_STATE_CONTRACT" ]; then
    echo "PROTOCOL_STATE_CONTRACT not found, please set this in your .env!";
    exit 1;
fi

if [ -z "$SIGNER_ACCOUNT_PRIVATE_KEY" ]; then
    echo "SIGNER_ACCOUNT_PRIVATE_KEY not found, please set this in your .env!";
    exit 1;
fi


echo "Found SOURCE RPC URL ${SOURCE_RPC_URL}";

echo "Found SIGNER ACCOUNT ADDRESS ${SIGNER_ACCOUNT_ADDRESS}";

if [ "$IPFS_URL" ]; then
    echo "Found IPFS_URL ${IPFS_URL}";
fi

if [ "$DATA_MARKET_CONTRACT" ]; then
    echo "Found DATA_MARKET_CONTRACT ${DATA_MARKET_CONTRACT}";
fi

if [ "$TELEGRAM_REPORTING_URL" ]; then
    echo "Found TELEGRAM_REPORTING_URL ${TELEGRAM_REPORTING_URL}";
fi

if [ "$TELEGRAM_CHAT_ID" ]; then
    echo "Found TELEGRAM_CHAT_ID ${TELEGRAM_CHAT_ID}";
fi

if [ "$TELEGRAM_NOTIFICATION_COOLDOWN" ]; then
    echo "Found TELEGRAM_NOTIFICATION_COOLDOWN ${TELEGRAM_NOTIFICATION_COOLDOWN}";
fi

if [ "$FULL_NAMESPACE" ]; then
    echo "Found FULL_NAMESPACE ${FULL_NAMESPACE}";
else
    echo "FULL_NAMESPACE not found, please set this in your .env!";
    exit 1;
fi

cp config/projects.example.json config/projects.json
cp config/settings.example.json config/settings.json


export namespace="${FULL_NAMESPACE:-namespace_hash}"
export ipfs_url="${IPFS_URL:-}"
export ipfs_api_key="${IPFS_API_KEY:-}"
export ipfs_api_secret="${IPFS_API_SECRET:-}"
export local_collector_port="${LOCAL_COLLECTOR_PORT:-50051}"
export telegram_reporting_url="${TELEGRAM_REPORTING_URL:-}"
export telegram_chat_id="${TELEGRAM_CHAT_ID:-}"
export telegram_message_thread_id="${TELEGRAM_MESSAGE_THREAD_ID:-}"
export telegram_notification_cooldown="${TELEGRAM_NOTIFICATION_COOLDOWN:-}"

# If IPFS_URL is empty, clear IPFS API key and secret
if [ -z "$IPFS_URL" ]; then
    ipfs_api_key=""
    ipfs_api_secret=""
fi

echo "Using FULL_NAMESPACE: ${namespace}"
echo "Using Powerloom RPC URL: ${POWERLOOM_RPC_URL}"
echo "Using IPFS URL: ${ipfs_url}"
echo "Using IPFS API KEY: ${ipfs_api_key}"
echo "Using protocol state contract: ${PROTOCOL_STATE_CONTRACT}"
echo "Using data market contract: ${DATA_MARKET_CONTRACT}"
echo "Using telegram reporting url: ${telegram_reporting_url}"
echo "Using telegram chat id: ${telegram_chat_id}"
echo "Using telegram notification cooldown: ${telegram_notification_cooldown}"

sed -i'.backup' "s#relevant-namespace#$namespace#" config/settings.json

sed -i'.backup' "s#account-address#$SIGNER_ACCOUNT_ADDRESS#" config/settings.json
sed -i'.backup' "s#slot-id#$SLOT_ID#" config/settings.json

sed -i'.backup' "s#https://rpc-url#$SOURCE_RPC_URL#" config/settings.json

sed -i'.backup' "s#https://powerloom-rpc-url#$POWERLOOM_RPC_URL#" config/settings.json

sed -i'.backup' "s#ipfs-writer-url#$ipfs_url#" config/settings.json
sed -i'.backup' "s#ipfs-writer-key#$ipfs_api_key#" config/settings.json
sed -i'.backup' "s#ipfs-writer-secret#$ipfs_api_secret#" config/settings.json

sed -i'.backup' "s#ipfs-reader-url#$ipfs_url#" config/settings.json
sed -i'.backup' "s#ipfs-reader-key#$ipfs_api_key#" config/settings.json
sed -i'.backup' "s#ipfs-reader-secret#$ipfs_api_secret#" config/settings.json

sed -i'.backup' "s#protocol-state-contract#$PROTOCOL_STATE_CONTRACT#" config/settings.json
sed -i'.backup' "s#data-market-contract#$DATA_MARKET_CONTRACT#" config/settings.json

sed -i'.backup' "s#signer-account-private-key#$SIGNER_ACCOUNT_PRIVATE_KEY#" config/settings.json

sed -i'.backup' "s#local-collector-port#$local_collector_port#" config/settings.json

sed -i'.backup' "s#https://telegram-reporting-url#$telegram_reporting_url#" config/settings.json
sed -i'.backup' "s#telegram-chat-id#$telegram_chat_id#" config/settings.json
sed -i'.backup' "s#telegram-notification-cooldown#$telegram_notification_cooldown#" config/settings.json
sed -i'.backup' "s#telegram-message-thread-id#$telegram_message_thread_id#" config/settings.json

echo 'settings has been populated!'
