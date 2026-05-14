package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
)

// bootstrap creates or resets the service API key and writes it to .apikey in dataDir.
// The .apikey file is the source of truth. If it doesn't exist (fresh install or migration
// from the old Keychain approach), any stale DB keys are cleared and a new key is created.
// If the file already exists, the service is already bootstrapped — return 403.
func (h *handler) bootstrap(w http.ResponseWriter, r *http.Request) {
	apiKeyPath := filepath.Join(h.dataDir, ".apikey")

	// File exists → already bootstrapped
	if _, err := os.Stat(apiKeyPath); err == nil {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}

	// File missing → clear any stale DB keys (migration from Keychain) and create fresh
	h.db.DeleteAllAPIKeys()

	plaintext, err := h.db.CreateAPIKey("mac-app")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	// Write key to file so the Mac app can read it without an HTTP call
	if err := os.WriteFile(apiKeyPath, []byte(plaintext), 0o600); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	jsonOK(w, map[string]string{"key": plaintext})
}

func jsonOK(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func httpError(w http.ResponseWriter, err error, code int) {
	http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), code)
}
