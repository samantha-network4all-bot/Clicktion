package api

import (
	"encoding/json"
	"net/http"

	"github.com/clicktion/service/internal/db"
)

type apiKeyResponse struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	CreatedAt string `json:"created_at"`
}

type createKeyRequest struct {
	Label string `json:"label"`
}

type createKeyResponse struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Key       string `json:"key"` // returned only on creation
	CreatedAt string `json:"created_at"`
}

func (h *handler) listAPIKeys(w http.ResponseWriter, r *http.Request) {
	keys, err := h.db.ListAPIKeys()
	if err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	out := make([]apiKeyResponse, len(keys))
	for i, k := range keys {
		out[i] = apiKeyResponse{ID: k.ID, Label: k.Label, CreatedAt: k.CreatedAt.Format("2006-01-02T15:04:05Z")}
	}
	jsonOK(w, out)
}

func (h *handler) createAPIKey(w http.ResponseWriter, r *http.Request) {
	var req createKeyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, err, http.StatusBadRequest)
		return
	}
	if req.Label == "" {
		req.Label = "default"
	}
	plaintext, err := h.db.CreateAPIKey(req.Label)
	if err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	// Fetch the created key to get its ID
	keys, _ := h.db.ListAPIKeys()
	var created db.APIKey
	for _, k := range keys {
		if k.Label == req.Label {
			created = k
			break
		}
	}
	w.WriteHeader(http.StatusCreated)
	jsonOK(w, createKeyResponse{
		ID:        created.ID,
		Label:     created.Label,
		Key:       plaintext,
		CreatedAt: created.CreatedAt.Format("2006-01-02T15:04:05Z"),
	})
}

func (h *handler) deleteAPIKey(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := h.db.DeleteAPIKey(id); err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
