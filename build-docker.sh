docker build -t snapshotter-lite-v2 .

#!/bin/bash

# Build the setup image
echo "🏗️ Building snapshotter-lite-setup image..."
docker build -f Dockerfile.setup -t snapshotter-lite-setup:latest .

if [ $? -eq 0 ]; then
    echo "✅ Setup image built successfully"
else
    echo "❌ Failed to build setup image"
    exit 1
fi