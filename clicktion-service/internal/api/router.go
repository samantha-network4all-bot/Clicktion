package api

import (
	"net/http"

	"github.com/clicktion/service/internal/db"
)

func NewRouter(database *db.DB, dataDir string) http.Handler {
	mux := http.NewServeMux()
	h := &handler{db: database, dataDir: dataDir}

	mux.Handle("/api/", authMiddleware(database, http.StripPrefix("/api", apiRoutes(h))))

	mux.Handle("/archive", http.HandlerFunc(h.serveArchive))
	mux.Handle("/archive/", http.HandlerFunc(h.serveArchive))
	mux.Handle("/admin", http.HandlerFunc(h.serveAdmin))
	mux.Handle("/admin/", http.HandlerFunc(h.serveAdmin))
	mux.Handle("/static/", http.StripPrefix("/static/", http.HandlerFunc(h.serveStatic)))

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	// Bootstrap: creates the first API key when no keys exist yet.
	// Returns 403 once any key exists, so it can only be called once.
	mux.HandleFunc("POST /bootstrap", func(w http.ResponseWriter, r *http.Request) {
		keys, err := database.ListAPIKeys()
		if err != nil || len(keys) > 0 {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		plaintext, err := database.CreateAPIKey("mac-app")
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		jsonOK(w, map[string]string{"key": plaintext})
	})

	return mux
}

func apiRoutes(h *handler) http.Handler {
	mux := http.NewServeMux()

	// Models
	mux.HandleFunc("GET /models", h.listModels)
	mux.HandleFunc("POST /models", h.createModel)
	mux.HandleFunc("PUT /models/{id}", h.updateModel)
	mux.HandleFunc("DELETE /models/{id}", h.deleteModel)
	mux.HandleFunc("POST /models/{id}/test", h.testModel)

	// Captures
	mux.HandleFunc("POST /captures", h.createCapture)
	mux.HandleFunc("GET /captures", h.listCaptures)
	mux.HandleFunc("GET /captures/{id}", h.getCapture)
	mux.HandleFunc("PATCH /captures/{id}", h.updateCapture)
	mux.HandleFunc("DELETE /captures/{id}", h.deleteCapture)

	// Jobs
	mux.HandleFunc("POST /jobs", h.createJob)
	mux.HandleFunc("GET /jobs/{id}/stream", h.streamJob)
	mux.HandleFunc("POST /jobs/{id}/messages", h.sendMessage)

	// API keys
	mux.HandleFunc("GET /auth/keys", h.listAPIKeys)
	mux.HandleFunc("POST /auth/keys", h.createAPIKey)
	mux.HandleFunc("DELETE /auth/keys/{id}", h.deleteAPIKey)

	return mux
}

type handler struct {
	db      *db.DB
	dataDir string
}
