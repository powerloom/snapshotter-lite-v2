docker build -t snapshotter-lite-v2 .

#!/bin/bash

# Build the setup container
echo "🏗️ Building snapshotter-lite-setup container..."
docker build -f Dockerfile.setup -t snapshotter-lite-setup:latest .

if [ $? -eq 0 ]; then
    echo "✅ Setup container built successfully"
else
    echo "❌ Failed to build setup container"
    exit 1
fi