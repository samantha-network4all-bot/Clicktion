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
	mux.Handle("/workflows", http.HandlerFunc(h.serveWorkflows))
	mux.Handle("/admin", http.HandlerFunc(h.serveAdmin))
	mux.Handle("/admin/", http.HandlerFunc(h.serveAdmin))
	mux.Handle("/static/", http.StripPrefix("/static/", http.HandlerFunc(h.serveStatic)))

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	mux.HandleFunc("POST /bootstrap", h.bootstrap)

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
	mux.HandleFunc("POST /models/{id}/setdefault", h.setDefaultModelAPI)

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

	// Storage
	mux.HandleFunc("POST /storage/prune", h.pruneStorage)

	return mux
}

type handler struct {
	db      *db.DB
	dataDir string
}
