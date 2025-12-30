package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"

	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/peer"
)

func main() {
	// Generate a new Ed25519 private key using libp2p's crypto library
	// This ensures compatibility with libp2p's peer ID generation
	priv, _, err := crypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		fmt.Printf("Error generating private key: %v\n", err)
		return
	}

	// Get the Peer ID from the private key to verify compatibility
	peerID, err := peer.IDFromPrivateKey(priv)
	if err != nil {
		fmt.Printf("Error getting Peer ID: %v\n", err)
		return
	}

	// Get the raw private key bytes (this is what libp2p stores)
	// Raw() returns the format that UnmarshalEd25519PrivateKey expects
	privateKeyBytes, err := priv.Raw()
	if err != nil {
		fmt.Printf("Error getting raw private key: %v\n", err)
		return
	}
	privateKeyHex := hex.EncodeToString(privateKeyBytes)

	fmt.Println("Generated Private Key (hex):", privateKeyHex)
	fmt.Println("Derived Peer ID:", peerID.String())
	fmt.Println("Key length:", len(privateKeyHex), "characters")
	fmt.Println("Note: This is libp2p-compatible and will generate correct peer IDs")
}
