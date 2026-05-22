package main

import (
	"crypto/rand"
	"encoding/hex"
	"log"
	"net/http"
	"os"
)

var jwtSecret []byte

func main() {
	dbPath := os.Getenv("DB_PATH")
	if dbPath == "" {
		dbPath = "/data/sync.db"
	}
	if err := initDB(dbPath); err != nil {
		log.Fatalf("DB init: %v", err)
	}
	defer db.Close() //nolint:errcheck

	secret, err := loadOrCreateJWTSecret()
	if err != nil {
		log.Fatalf("JWT secret: %v", err)
	}
	jwtSecret = []byte(secret)

	mux := http.NewServeMux()

	// Auth
	mux.HandleFunc("POST /api/auth/register", handleRegister)
	mux.HandleFunc("POST /api/auth/login", handleLogin)
	mux.HandleFunc("POST /api/auth/refresh", handleRefresh)

	// Sync (all require a valid Bearer token)
	mux.HandleFunc("GET /api/sync/state", requireAuth(handleSyncState))
	mux.HandleFunc("GET /api/sync/conversations/{id}", requireAuth(handleGetConversation))
	mux.HandleFunc("PUT /api/sync/conversations/{id}", requireAuth(handlePutConversation))
	mux.HandleFunc("DELETE /api/sync/conversations/{id}", requireAuth(handleDeleteConversation))
	mux.HandleFunc("GET /api/sync/settings", requireAuth(handleGetSettings))
	mux.HandleFunc("PUT /api/sync/settings", requireAuth(handlePutSettings))

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	log.Printf("LocalLLMChat sync server listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

func loadOrCreateJWTSecret() (string, error) {
	// Use env override if provided (recommended for all deployments).
	if s := os.Getenv("JWT_SECRET"); s != "" {
		return s, nil
	}

	// No env var — fall back to a secret persisted in the DB.
	// This is less secure because anyone with read access to the DB file can
	// forge tokens.  Set JWT_SECRET in the environment to eliminate this risk.
	// Generate a strong secret with:  openssl rand -hex 32
	log.Println("WARNING: JWT_SECRET environment variable is not set.")
	log.Println("WARNING: Using a DB-stored secret. Set JWT_SECRET for production deployments.")

	val, err := getConfig("jwt_secret")
	if err == nil && val != "" {
		return val, nil
	}
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	secret := hex.EncodeToString(b)
	return secret, setConfig("jwt_secret", secret)
}
