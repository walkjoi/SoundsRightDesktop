#!/bin/bash
# Setup script for Kokoro TTS server
# Run this once to install dependencies

set -e

echo "Installing Kokoro TTS dependencies..."
pip3 install -r "$(dirname "$0")/requirements.txt"

echo ""
echo "Testing Kokoro installation..."
python3 -c "from kokoro import KPipeline; print('Kokoro installed successfully')"

echo ""
echo "Setup complete. Start the server with:"
echo "  python3 $(dirname "$0")/kokoro_server.py"
