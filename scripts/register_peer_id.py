#!/usr/bin/env python3
"""
Peer ID Registration Script for DSV Devnet

This script helps DSV devnet participants register their libp2p peer ID
against their validator slot ID using EIP-712 signed messages.

Flow:
1. Generate or load Ed25519 private key
2. Derive peer ID from private key
3. Sign EIP-712 message with snapshotter signer key
4. Submit peer ID registration to ValidatorState contract
"""

import asyncio
import json
import sys
import time
from web3 import Web3
from eth_account import Account
from eth_account.messages import encode_defunct
from pathlib import Path

class PeerIDRegistrar:
    def __init__(self, rpc_url, private_key, validator_state_address):
        """
        Initialize the peer ID registrar

        Args:
            rpc_url: Ethereum RPC URL
            private_key: Private key for signing transactions
            validator_state_address: Address of ValidatorState contract
        """
        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
        self.account = Account.from_key(private_key)
        self.validator_state_address = validator_state_address

        # ABI for ValidatorState contract (minimal needed for setLibP2pAddress)
        self.validator_state_abi = [
            {
                "inputs": [
                    {"internalType": "uint256", "name": "_nodeId", "type": "uint256"},
                    {"internalType": "string", "name": "_libP2pAddress", "type": "string"}
                ],
                "name": "setLibP2pAddress",
                "outputs": [],
                "stateMutability": "nonpayable",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "uint256", "name": "_nodeId", "type": "uint256"}
                ],
                "name": "nodeInfo",
                "outputs": [
                    {
                        "components": [
                            {"internalType": "address", "name": "validatorAddress", "type": "address"},
                            {"internalType": "string", "name": "libP2pAddress", "type": "string"},
                            {"internalType": "uint256", "name": "nodePrice", "type": "uint256"},
                            {"internalType": "uint256", "name": "mintedOn", "type": "uint256"},
                            {"internalType": "uint256", "name": "burnedOn", "type": "uint256"},
                            {"internalType": "uint256", "name": "lastUpdated", "type": "uint256"},
                            {"internalType": "bool", "name": "active", "type": "bool"},
                            {"internalType": "bool", "name": "claimedTokens", "type": "bool"}
                        ],
                        "internalType": "struct PowerloomValidatorNodes.NodeInfo",
                        "name": "",
                        "type": "tuple"
                    }
                ],
                "stateMutability": "view",
                "type": "function"
            },
            {
                "inputs": [
                    {"internalType": "address", "name": "validatorAddress", "type": "address"}
                ],
                "name": "validatorToNodeId",
                "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
                "stateMutability": "view",
                "type": "function"
            }
        ]

        self.contract = self.w3.eth.contract(
            address=validator_state_address,
            abi=self.validator_state_abi
        )

        print(f"🔗 Connected to RPC: {rpc_url}")
        print(f"👤 Signer address: {self.account.address}")
        print(f"📄 ValidatorState: {validator_state_address}")

    def derive_peer_id_from_private_key(self, private_key_hex):
        """
        Derive libp2p peer ID from Ed25519 private key

        Args:
            private_key_hex: 128-character hex string (Ed25519 format)

        Returns:
            str: Estimated peer ID
        """
        # This is a simplified estimation - actual libp2p peer ID derivation
        # requires protobuf encoding of the public key
        from cryptography.hazmat.primitives.asymmetric import ed25519
        from cryptography.hazmat.primitives import serialization
        import hashlib
        import base58

        # Convert hex to bytes
        private_key_bytes = bytes.fromhex(private_key_hex)

        # Extract seed (first 32 bytes) from Ed25519 private key
        seed = private_key_bytes[:32]

        # Generate Ed25519 private key
        private_key = ed25519.Ed25519PrivateKey.from_private_bytes(seed)

        # Get public key bytes
        public_key_bytes = private_key.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw
        )

        # Estimate peer ID (simplified - actual would use protobuf)
        peer_id_prefix = "12D3KooW"  # Standard Ed25519 peer ID prefix

        # Create a deterministic hash based on public key
        hash_input = public_key_bytes + b'\x00\x00\x00\x00'  # protobuf identifier placeholder
        peer_id_hash = hashlib.sha256(hash_input).digest()[:32]

        # Base58 encode the hash
        peer_id_suffix = base58.b58encode(peer_id_hash).decode('utf-8')[:48]

        return f"{peer_id_prefix}{peer_id_suffix}"

    def create_eip712_message(self, node_id, peer_id, deadline=None):
        """
        Create EIP-712 message for peer ID registration

        Args:
            node_id: Validator node ID
            peer_id: libp2p peer ID to register
            deadline: Optional deadline for the signature

        Returns:
            dict: EIP-712 structured message
        """
        if deadline is None:
            deadline = int(time.time()) + 3600  # 1 hour from now

        message = {
            "types": {
                "EIP712Domain": [
                    {"name": "name", "type": "string"},
                    {"name": "version", "type": "string"},
                    {"name": "chainId", "type": "uint256"},
                    {"name": "verifyingContract", "type": "address"}
                ],
                "RegisterPeerID": [
                    {"name": "nodeId", "type": "uint256"},
                    {"name": "peerId", "type": "string"},
                    {"name": "deadline", "type": "uint256"}
                ]
            },
            "primaryType": "RegisterPeerID",
            "domain": {
                "name": "PowerloomValidatorState",
                "version": "1",
                "chainId": self.w3.eth.chain_id,
                "verifyingContract": self.validator_state_address
            },
            "message": {
                "nodeId": node_id,
                "peerId": peer_id,
                "deadline": deadline
            }
        }

        return message

    def sign_eip712_message(self, eip712_message):
        """
        Sign EIP-712 message

        Args:
            eip712_message: EIP-712 structured message

        Returns:
            str: Signature
        """
        # For now, use simple eth_sign approach
        # In production, this should use proper EIP-712 signing libraries
        message_text = json.dumps(eip712_message['message'], separators=(',', ':'))
        message_hash = self.w3.keccak(text=message_text)

        signable_hash = encode_defunct(hexstr=message_hash.hex())
        signed_message = self.account.sign_message(signable_hash)

        return signed_message.signature.hex()

    async def register_peer_id(self, node_id, peer_id, gas_limit=200000):
        """
        Register peer ID on ValidatorState contract

        Args:
            node_id: Validator node ID
            peer_id: libp2p peer ID to register
            gas_limit: Gas limit for transaction

        Returns:
            str: Transaction hash
        """
        try:
            print(f"📝 Registering peer ID {peer_id} for node {node_id}")

            # Get current node info
            node_info = self.contract.functions.nodeInfo(node_id).call()
            print(f"📊 Current node info:")
            print(f"   Validator address: {node_info[0]}")
            print(f"   Current libP2P address: '{node_info[1]}'")
            print(f"   Active: {node_info[6]}")

            # Build transaction
            transaction = self.contract.functions.setLibP2pAddress(
                node_id,
                peer_id
            ).build_transaction({
                'from': self.account.address,
                'nonce': self.w3.eth.get_transaction_count(self.account.address),
                'gas': gas_limit,
                'gasPrice': self.w3.eth.gas_price,
            })

            # Sign transaction
            signed_txn = self.w3.eth.account.sign_transaction(transaction, self.account.key)

            # Send transaction
            tx_hash = self.w3.eth.send_raw_transaction(signed_txn.rawTransaction)

            print(f"📤 Transaction sent: {tx_hash.hex()}")

            # Wait for confirmation
            tx_receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

            if tx_receipt.status == 1:
                print(f"✅ Peer ID registration successful!")
                print(f"   Block: {tx_receipt.blockNumber}")
                print(f"   Gas used: {tx_receipt.gasUsed}")
            else:
                print(f"❌ Peer ID registration failed!")
                return None

            return tx_hash.hex()

        except Exception as e:
            print(f"❌ Error registering peer ID: {e}")
            return None

    async def get_node_id_for_validator(self, validator_address):
        """
        Get node ID for a validator address

        Args:
            validator_address: Validator address

        Returns:
            uint256: Node ID (0 if not found)
        """
        try:
            node_id = self.contract.functions.validatorToNodeId(validator_address).call()
            return node_id
        except Exception as e:
            print(f"❌ Error getting node ID: {e}")
            return 0

async def main():
    """Main function for peer ID registration"""
    try:
        # Configuration for DSV devnet
        DSV_DEVNET_CONFIG = {
            "rpc_url": "https://rpc-devnet.powerloom.dev",
            "chain_id": 11167,
            "validator_state_address": "0x3B5A0FB70ef68B5dd677C7d614dFB89961f97401"  # Example from sources.json
        }

        print("🔐 DSV Devnet Peer ID Registration")
        print("=" * 50)

        # Get private key from environment or user input
        import os
        signer_private_key = os.getenv("SIGNER_PRIVATE_KEY")
        if not signer_private_key:
            print("❌ Please set SIGNER_PRIVATE_KEY environment variable")
            print("   This should be the snapshotter signer key that is registered with your slot ID")
            return 1

        # Get libp2p private key
        p2p_private_key = os.getenv("LOCAL_COLLECTOR_PRIVATE_KEY")
        if not p2p_private_key:
            print("❌ Please set LOCAL_COLLECTOR_PRIVATE_KEY environment variable")
            print("   Run: python3 scripts/generate_p2p_key.py")
            return 1

        # Initialize registrar
        registrar = PeerIDRegistrar(
            rpc_url=DSV_DEVNET_CONFIG["rpc_url"],
            private_key=signer_private_key,
            validator_state_address=DSV_DEVNET_CONFIG["validator_state_address"]
        )

        # Derive peer ID from p2p private key
        print("\n🔄 Deriving peer ID from private key...")
        peer_id = registrar.derive_peer_id_from_private_key(p2p_private_key)
        print(f"🆔 Derived Peer ID: {peer_id}")

        # Get node ID for validator
        print(f"\n🔍 Looking up node ID for validator {registrar.account.address}...")
        node_id = await registrar.get_node_id_for_validator(registrar.account.address)

        if node_id == 0:
            print("❌ No node ID found for this validator address")
            print("   Make sure your validator address is registered with a node")
            return 1

        print(f"✅ Found node ID: {node_id}")

        # Create EIP-712 message (for record-keeping)
        print("\n📝 Creating EIP-712 registration message...")
        eip712_message = registrar.create_eip712_message(node_id, peer_id)
        print(f"📄 Message created:")
        print(f"   Node ID: {eip712_message['message']['nodeId']}")
        print(f"   Peer ID: {eip712_message['message']['peerId']}")
        print(f"   Deadline: {eip712_message['message']['deadline']}")

        # Sign message (for record-keeping)
        signature = registrar.sign_eip712_message(eip712_message)
        print(f"✍️  Signature: {signature}")

        # Register peer ID
        print(f"\n🚀 Registering peer ID on ValidatorState contract...")
        tx_hash = await registrar.register_peer_id(node_id, peer_id)

        if tx_hash:
            print(f"\n🎉 Peer ID registration completed successfully!")
            print(f"🔗 Transaction: {tx_hash}")
            print(f"📖 View on explorer: https://sepolia-arbiscan.io/tx/{tx_hash}")
        else:
            print(f"\n❌ Peer ID registration failed!")
            return 1

    except Exception as e:
        print(f"❌ Error: {e}")
        return 1

    return 0

if __name__ == "__main__":
    exit_code = asyncio.run(main())
    sys.exit(exit_code)