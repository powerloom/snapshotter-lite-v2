#!/usr/bin/env python3
"""
Private Key Generation for P2P Node (Python-Go Compatibility)

This script generates a private key that's compatible with both Python and Go libp2p implementations.
The key is generated using Ed25519 (same as Go libp2p) and formatted for cross-compatibility.
"""

import secrets
import sys
import hashlib
import base64
from cryptography.hazmat.primitives.asymmetric import ed25519
from cryptography.hazmat.primitives import serialization

def generate_ed25519_private_key():
    """
    Generate an Ed25519 private key compatible with Go libp2p

    Go libp2p uses Ed25519 keys which are 64 bytes (128 hex characters):
    - 32 bytes seed + 32 bytes public key concatenated
    - This matches crypto.GenerateEd25519Key() in Go

    Returns:
        tuple: (private_key_hex, estimated_peer_id)
    """
    # Generate Ed25519 private key using cryptography library
    private_key = ed25519.Ed25519PrivateKey.generate()

    # Get the raw private key bytes (32 bytes seed)
    private_seed_bytes = private_key.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption()
    )

    # Get the public key bytes (32 bytes)
    public_key_bytes = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw
    )

    # Concatenate seed + public_key = 64 bytes total (Ed25519 format in Go libp2p)
    # This matches what Go's GenerateEd25519Key() returns
    full_private_key_bytes = private_seed_bytes + public_key_bytes
    private_key_hex = full_private_key_bytes.hex()

    # Generate estimated peer ID (placeholder for now)
    # In Go libp2p, peer ID is derived from the public key using protobuf
    # The exact derivation would require protobuf integration
    # For our purposes, we'll create a deterministic placeholder
    peer_id_prefix = "12D3KooW"  # Standard Ed25519 peer ID prefix in libp2p
    peer_id_hash = hashlib.sha256(public_key_bytes).hexdigest()[:48]
    estimated_peer_id = f"{peer_id_prefix}{peer_id_hash}"

    return private_key_hex, estimated_peer_id

def main():
    """Main function to generate and display the private key"""
    try:
        print("🔐 Generating Ed25519 P2P private key for DSV devnet node...")

        private_key_hex, estimated_peer_id = generate_ed25519_private_key()

        print(f"✅ Private Key Generated:")
        print(f"   Private Key (hex): {private_key_hex}")
        print(f"   Estimated Peer ID: {estimated_peer_id}")
        print()

        # Output in format suitable for environment files
        print(f"📝 Environment Variable Format:")
        print(f"LOCAL_COLLECTOR_PRIVATE_KEY={private_key_hex}")
        print()

        # Test the key format
        print("🧪 Testing Key Format:")
        print(f"   Key length: {len(private_key_hex)} characters")
        print(f"   Valid hex: {all(c in '0123456789abcdefABCDEF' for c in private_key_hex)}")
        print(f"   Expected length (Ed25519): 128 characters")
        print(f"   Key starts with: {private_key_hex[:16]}...")

        if len(private_key_hex) == 128 and all(c in '0123456789abcdefABCDEF' for c in private_key_hex):
            print("✅ Ed25519 key format is valid")
        else:
            print("❌ Key format is invalid - should be 128 hex characters")
            return 1

        print()
        print("📋 Key Compatibility Notes:")
        print("   - Ed25519 format matches Go libp2p GenerateEd25519Key()")
        print("   - Peer ID estimation requires actual libp2p protobuf derivation")
        print("   - This key format should work with both Python and Go libp2p")
        print("   - Test with actual libp2p implementations before production use")

    except Exception as e:
        print(f"❌ Error generating private key: {e}")
        return 1

    return 0

if __name__ == "__main__":
    sys.exit(main())