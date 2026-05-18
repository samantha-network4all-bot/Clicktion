package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/clicktion/service/internal/db"
)

// MARK: - Notebook detail (read-only in P1)

// CellView is what the template renders: the raw NotebookCell plus a
// preloaded Capture row for capture cells (so the template doesn't have to
// run queries to display the image + OCR).
type CellView struct {
	db.NotebookCell
	Capture *db.Capture
}

type notebookPage struct {
	Notebook       *db.Notebook
	Cells          []CellView
	LatestJobID    string // "" if the notebook has no jobs yet (typical for fresh todos)
	HasResponseCell bool  // true → show follow-up input; false → show "pick a skill" hint
}

func (h *handler) serveNotebook(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/notebooks")

	// POST /notebooks/{id}/done — mark a todo as completed.
	if strings.HasSuffix(path, "/done") && r.Method == http.MethodPost {
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/done")
		h.markNotebookDone(w, r, id)
		return
	}

	// POST /notebooks/{id}/follow-up — browser-side follow-up message.
	// Returns JSON { job_id } so the page can subscribe to the stream.
	if strings.HasSuffix(path, "/follow-up") && r.Method == http.MethodPost {
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/follow-up")
		h.notebookFollowUp(w, r, id)
		return
	}

	// GET /notebooks/{id}/stream?job=X — browser-side SSE (no Bearer auth).
	if strings.HasSuffix(path, "/stream") && r.Method == http.MethodGet {
		jobID := r.URL.Query().Get("job")
		if jobID == "" {
			http.Error(w, "missing job param", http.StatusBadRequest)
			return
		}
		h.writeJobStream(w, r, jobID)
		return
	}

	// GET /notebooks/{id}
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	id := strings.TrimPrefix(path, "/")
	if id == "" || strings.Contains(id, "/") {
		http.NotFound(w, r)
		return
	}

	nb, err := h.db.GetNotebook(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if nb == nil {
		http.NotFound(w, r)
		return
	}

	cells, err := h.db.ListNotebookCells(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	views := make([]CellView, 0, len(cells))
	var primaryCaptureID string
	hasResponse := false
	for _, c := range cells {
		v := CellView{NotebookCell: c}
		if c.Kind == db.CellCapture && c.CaptureID != nil {
			if primaryCaptureID == "" {
				primaryCaptureID = *c.CaptureID
			}
			if cap, err := h.db.GetCapture(*c.CaptureID); err == nil {
				v.Capture = cap
			}
		}
		if c.Kind == db.CellResponse {
			hasResponse = true
		}
		views = append(views, v)
	}

	var latestJobID string
	if primaryCaptureID != "" {
		latestJobID, _ = h.db.LatestJobIDForCapture(primaryCaptureID)
	}

	renderTemplate(w, notebookTmpl, "notebook.html", notebookPage{
		Notebook:        nb,
		Cells:           views,
		LatestJobID:     latestJobID,
		HasResponseCell: hasResponse,
	})
}

func (h *handler) markNotebookDone(w http.ResponseWriter, r *http.Request, id string) {
	if err := h.db.MarkNotebookDone(id); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/notebooks/"+id, http.StatusSeeOther)
}

// notebookFollowUp accepts a follow-up message from the browser, persists it
// as a markdown cell + chat_message, restarts the most recent job, and
// returns { job_id } so the page can open an EventSource on the stream.
func (h *handler) notebookFollowUp(w http.ResponseWriter, r *http.Request, notebookID string) {
	// Body can be JSON ({message}) or form-encoded.
	var msg string
	if r.Header.Get("Content-Type") == "application/json" {
		var body struct {
			Message string `json:"message"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		msg = body.Message
	} else {
		if err := r.ParseForm(); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		msg = r.FormValue("message")
	}
	if msg = strings.TrimSpace(msg); msg == "" {
		http.Error(w, "empty message", http.StatusBadRequest)
		return
	}

	// Resolve notebook → capture (primary capture cell) → latest job.
	cells, err := h.db.ListNotebookCells(notebookID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	var captureID string
	for _, c := range cells {
		if c.Kind == db.CellCapture && c.CaptureID != nil {
			captureID = *c.CaptureID
			break
		}
	}
	if captureID == "" {
		http.Error(w, "notebook has no capture cell", http.StatusBadRequest)
		return
	}
	jobID, err := h.db.LatestJobIDForCapture(captureID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if jobID == "" {
		http.Error(w, "no existing job — pick a skill first", http.StatusBadRequest)
		return
	}

	// Persist the user message + mirror to notebook cells.
	h.db.AddChatMessage(db.ChatMessage{
		CaptureID: captureID,
		Role:      "user",
		Content:   msg,
	})
	h.db.AppendCellByCapture(captureID, db.NotebookCell{
		Kind:    db.CellMarkdown,
		Content: msg,
	})

	// Re-run the job.
	h.db.UpdateJobStatus(jobID, "running")
	h.runJob(jobID)

	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"job_id":"%s"}`, jobID)
}
