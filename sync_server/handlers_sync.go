package main

import (
	"encoding/json"
	"net/http"
	"time"
)

// ── State ─────────────────────────────────────────────────────────────────────

type convMeta struct {
	ID        string `json:"id"`
	UpdatedAt string `json:"updated_at"`
	Deleted   bool   `json:"deleted"`
}

type syncStateResponse struct {
	Conversations     []convMeta `json:"conversations"`
	SettingsUpdatedAt string     `json:"settings_updated_at,omitempty"`
}

// GET /api/sync/state — returns metadata for all conversations and settings
// so the client can decide what to push or pull without downloading blobs.
func handleSyncState(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value(ctxUserID).(string)

	rows, err := db.Query(
		"SELECT id, updated_at, deleted FROM conversations WHERE user_id = ?",
		userID,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}
	defer rows.Close()

	convs := make([]convMeta, 0)
	for rows.Next() {
		var m convMeta
		var deleted int
		if err := rows.Scan(&m.ID, &m.UpdatedAt, &deleted); err != nil {
			continue
		}
		m.Deleted = deleted != 0
		convs = append(convs, m)
	}

	var settingsUpdatedAt string
	// Error is fine here — just means no settings exist yet.
	db.QueryRow( //nolint:errcheck
		"SELECT updated_at FROM user_settings WHERE user_id = ?", userID,
	).Scan(&settingsUpdatedAt)

	writeJSON(w, http.StatusOK, syncStateResponse{
		Conversations:     convs,
		SettingsUpdatedAt: settingsUpdatedAt,
	})
}

// ── Conversations ─────────────────────────────────────────────────────────────

type convBlob struct {
	ID            string `json:"id"`
	EncryptedBlob string `json:"encrypted_blob"`
	UpdatedAt     string `json:"updated_at"`
}

// GET /api/sync/conversations/{id}
func handleGetConversation(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value(ctxUserID).(string)
	id := r.PathValue("id")

	var blob convBlob
	err := db.QueryRow(
		`SELECT id, encrypted_blob, updated_at
		 FROM conversations
		 WHERE id = ? AND user_id = ? AND deleted = 0`,
		id, userID,
	).Scan(&blob.ID, &blob.EncryptedBlob, &blob.UpdatedAt)
	if err != nil {
		writeError(w, http.StatusNotFound, "not found")
		return
	}
	writeJSON(w, http.StatusOK, blob)
}

type putConvRequest struct {
	EncryptedBlob string `json:"encrypted_blob"`
	UpdatedAt     string `json:"updated_at"`
}

// PUT /api/sync/conversations/{id}
func handlePutConversation(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value(ctxUserID).(string)
	id := r.PathValue("id")

	var req putConvRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if req.EncryptedBlob == "" || req.UpdatedAt == "" {
		writeError(w, http.StatusBadRequest, "encrypted_blob and updated_at required")
		return
	}
	if _, err := time.Parse(time.RFC3339, req.UpdatedAt); err != nil {
		writeError(w, http.StatusBadRequest, "updated_at must be RFC3339")
		return
	}

	_, err := db.Exec(`
		INSERT INTO conversations(id, user_id, encrypted_blob, updated_at, deleted)
		VALUES (?, ?, ?, ?, 0)
		ON CONFLICT(id, user_id) DO UPDATE SET
		  encrypted_blob = excluded.encrypted_blob,
		  updated_at     = excluded.updated_at,
		  deleted        = 0`,
		id, userID, req.EncryptedBlob, req.UpdatedAt,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"id": id})
}

// DELETE /api/sync/conversations/{id} — soft-delete (tombstone)
func handleDeleteConversation(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value(ctxUserID).(string)
	id := r.PathValue("id")

	now := time.Now().UTC().Format(time.RFC3339)
	_, err := db.Exec(`
		INSERT INTO conversations(id, user_id, encrypted_blob, updated_at, deleted)
		VALUES (?, ?, '', ?, 1)
		ON CONFLICT(id, user_id) DO UPDATE SET
		  updated_at = excluded.updated_at,
		  deleted    = 1`,
		id, userID, now,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ── Settings ──────────────────────────────────────────────────────────────────

type settingsBlob struct {
	EncryptedBlob string `json:"encrypted_blob"`
	UpdatedAt     string `json:"updated_at"`
}

// GET /api/sync/settings
func handleGetSettings(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value(ctxUserID).(string)

	var blob settingsBlob
	err := db.QueryRow(
		"SELECT encrypted_blob, updated_at FROM user_settings WHERE user_id = ?",
		userID,
	).Scan(&blob.EncryptedBlob, &blob.UpdatedAt)
	if err != nil {
		writeError(w, http.StatusNotFound, "no settings synced yet")
		return
	}
	writeJSON(w, http.StatusOK, blob)
}

// PUT /api/sync/settings
func handlePutSettings(w http.ResponseWriter, r *http.Request) {
	userID := r.Context().Value(ctxUserID).(string)

	var req settingsBlob
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if req.EncryptedBlob == "" || req.UpdatedAt == "" {
		writeError(w, http.StatusBadRequest, "encrypted_blob and updated_at required")
		return
	}

	_, err := db.Exec(`
		INSERT INTO user_settings(user_id, encrypted_blob, updated_at)
		VALUES (?, ?, ?)
		ON CONFLICT(user_id) DO UPDATE SET
		  encrypted_blob = excluded.encrypted_blob,
		  updated_at     = excluded.updated_at`,
		userID, req.EncryptedBlob, req.UpdatedAt,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "db error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
