package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"

	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/multiformats/go-multiaddr"
)

func main() {
	// Generate a new Ed25519 private key
	priv, _, err := crypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		fmt.Printf("Error generating private key: %v\n", err)
		return
	}

	// Get the Peer ID from the private key
	peerID, err := peer.IDFromPrivateKey(priv)
	if err != nil {
		fmt.Printf("Error getting Peer ID: %v\n", err)
		return
	}

	// Encode the raw private key to hex for storage (64 bytes = 128 hex characters)
	// This is the crucial part: priv.Raw() gives the raw Ed25519 key bytes.
	privateKeyBytes, err := priv.Raw()
	if err != nil {
		fmt.Printf("Error getting raw private key: %v\n", err)
		return
	}
	privateKeyHex := hex.EncodeToString(privateKeyBytes)

	// Construct a multiaddress (using a placeholder IP and default port 4001)
	// You will need to replace 127.0.0.1 with your actual public IP address
	// when configuring other nodes to connect to your bootstrap node.
	multiAddrStr := fmt.Sprintf("/ip4/127.0.0.1/tcp/4001/p2p/%s", peerID.String())
	_, err = multiaddr.NewMultiaddr(multiAddrStr) // Validate multiaddress format
	if err != nil {
		fmt.Printf("Error creating multiaddress: %v\n", err)
		return
	}

	fmt.Println("Generated Private Key (hex):", privateKeyHex)
	fmt.Println("Derived Peer ID:", peerID.String())
	fmt.Println("Expected Multiaddress (local placeholder):", multiAddrStr)
	fmt.Println("\nRemember to replace '127.0.0.1' with your bootstrap node's public IP address when configuring other nodes.")
}