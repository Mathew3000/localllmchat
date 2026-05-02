package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
)

const (
	accessTokenTTL  = time.Hour
	refreshTokenTTL = 30 * 24 * time.Hour
	bcryptCost      = 12
)

// ── Register ──────────────────────────────────────────────────────────────────

type registerRequest struct {
	// Username is the human-readable account name.
	Username string `json:"username"`
	// AuthHash is PBKDF2(password, username+":auth:v1", 100_000) computed by
	// the client. The server bcrypt's this value — plaintext never touches disk.
	AuthHash string `json:"auth_hash"`
}

func handleRegister(w http.ResponseWriter, r *http.Request) {
	var req registerRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	req.Username = strings.TrimSpace(req.Username)
	if req.Username == "" || req.AuthHash == "" {
		writeError(w, http.StatusBadRequest, "username and auth_hash required")
		return
	}
	if l := len(req.Username); l < 3 || l > 64 {
		writeError(w, http.StatusBadRequest, "username must be 3–64 characters")
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.AuthHash), bcryptCost)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "hashing error")
		return
	}

	idBytes := make([]byte, 16)
	rand.Read(idBytes) //nolint:errcheck
	userID := hex.EncodeToString(idBytes)

	if _, err := db.Exec(
		"INSERT INTO users(id, username, auth_hash) VALUES (?, ?, ?)",
		userID, req.Username, string(hash),
	); err != nil {
		if strings.Contains(err.Error(), "UNIQUE") {
			writeError(w, http.StatusConflict, "username already taken")
		} else {
			writeError(w, http.StatusInternalServerError, "db error")
		}
		return
	}

	resp, err := issueTokens(userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "token error")
		return
	}
	writeJSON(w, http.StatusCreated, resp)
}

// ── Login ─────────────────────────────────────────────────────────────────────

type loginRequest struct {
	Username string `json:"username"`
	AuthHash string `json:"auth_hash"`
}

func handleLogin(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	req.Username = strings.TrimSpace(req.Username)

	var userID, storedHash string
	if err := db.QueryRow(
		"SELECT id, auth_hash FROM users WHERE username = ? COLLATE NOCASE",
		req.Username,
	).Scan(&userID, &storedHash); err != nil {
		// Constant-time: still run bcrypt to prevent timing oracle.
		bcrypt.CompareHashAndPassword([]byte(storedHash), []byte(req.AuthHash)) //nolint:errcheck
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(storedHash), []byte(req.AuthHash)); err != nil {
		writeError(w, http.StatusUnauthorized, "invalid credentials")
		return
	}

	resp, err := issueTokens(userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "token error")
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

// ── Refresh ───────────────────────────────────────────────────────────────────

type refreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

func handleRefresh(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}

	var userID, expiresAt string
	if err := db.QueryRow(
		"SELECT user_id, expires_at FROM refresh_tokens WHERE token = ?",
		req.RefreshToken,
	).Scan(&userID, &expiresAt); err != nil {
		writeError(w, http.StatusUnauthorized, "invalid refresh token")
		return
	}

	exp, _ := time.Parse(time.RFC3339, expiresAt)
	if time.Now().After(exp) {
		db.Exec("DELETE FROM refresh_tokens WHERE token = ?", req.RefreshToken) //nolint:errcheck
		writeError(w, http.StatusUnauthorized, "refresh token expired, please log in again")
		return
	}

	// Rotate: delete the consumed token, issue a fresh pair.
	db.Exec("DELETE FROM refresh_tokens WHERE token = ?", req.RefreshToken) //nolint:errcheck

	resp, err := issueTokens(userID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "token error")
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

// ── Helpers ───────────────────────────────────────────────────────────────────

type authResponse struct {
	UserID       string `json:"user_id"`
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
}

func issueTokens(userID string) (*authResponse, error) {
	access, err := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub": userID,
		"exp": time.Now().Add(accessTokenTTL).Unix(),
		"iat": time.Now().Unix(),
	}).SignedString(jwtSecret)
	if err != nil {
		return nil, err
	}

	rtBytes := make([]byte, 32)
	if _, err := rand.Read(rtBytes); err != nil {
		return nil, err
	}
	refreshTok := hex.EncodeToString(rtBytes)
	expiresAt := time.Now().Add(refreshTokenTTL).UTC().Format(time.RFC3339)

	if _, err := db.Exec(
		"INSERT INTO refresh_tokens(token, user_id, expires_at) VALUES (?, ?, ?)",
		refreshTok, userID, expiresAt,
	); err != nil {
		return nil, err
	}

	return &authResponse{
		UserID:       userID,
		AccessToken:  access,
		RefreshToken: refreshTok,
	}, nil
}
