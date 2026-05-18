package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"path/filepath"
	"strings"

	"github.com/clicktion/service/internal/db"
	"github.com/clicktion/service/internal/skills"
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
	Notebook        *db.Notebook
	Cells           []CellView
	LatestJobID     string        // "" if the notebook has no jobs yet (typical for fresh todos)
	HasResponseCell bool          // true → show follow-up input; false → show skill picker
	Skills          []skills.Skill
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

	// POST /notebooks/{id}/run-skill — first-time skill run on a notebook
	// that doesn't have a job yet (typical for todos picked up in the browser).
	if strings.HasSuffix(path, "/run-skill") && r.Method == http.MethodPost {
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/run-skill")
		h.notebookRunSkill(w, r, id)
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

	// Only load skills when we'll actually show the picker (no response cell
	// yet, todo not done). Saves a directory scan on the common case.
	var skillList []skills.Skill
	if !hasResponse && !nb.TodoDone {
		skillList, _ = skills.LoadAll(filepath.Join(h.dataDir, "skills"))
	}

	renderTemplate(w, notebookTmpl, "notebook.html", notebookPage{
		Notebook:        nb,
		Cells:           views,
		LatestJobID:     latestJobID,
		HasResponseCell: hasResponse,
		Skills:          skillList,
	})
}

func (h *handler) markNotebookDone(w http.ResponseWriter, r *http.Request, id string) {
	if err := h.db.MarkNotebookDone(id); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/notebooks/"+id, http.StatusSeeOther)
}

// notebookRunSkill creates a fresh job for a notebook that doesn't have one
// yet — typical when a Todo is picked up from the browser. The user picks
// a skill from the in-page list; we load the .md, build the job, and stream
// the response back via the existing SSE plumbing.
func (h *handler) notebookRunSkill(w http.ResponseWriter, r *http.Request, notebookID string) {
	var body struct {
		SkillName string `json:"skill_name"`
		InputMode string `json:"input_mode"` // optional override
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if body.SkillName == "" {
		http.Error(w, "skill_name required", http.StatusBadRequest)
		return
	}

	skill, err := skills.FindByName(filepath.Join(h.dataDir, "skills"), body.SkillName)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if skill == nil {
		http.Error(w, "unknown skill", http.StatusBadRequest)
		return
	}

	// Find the primary capture cell.
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

	// Decide send_image / send_ocr from the requested mode (default = both).
	mode := body.InputMode
	if mode == "" {
		mode = skill.InputMode
	}
	sendImage := mode != "text_only"
	sendOCR := mode != "image_only"

	skillName := skill.Name
	skillPrompt := skill.SystemPrompt

	job, err := h.db.CreateJob(db.Job{
		CaptureID:   captureID,
		SkillName:   &skillName,
		SkillPrompt: &skillPrompt,
		SendImage:   sendImage,
		SendOCR:     sendOCR,
		Temperature: -1, // model default
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	h.db.UpdateJobStatus(job.ID, "running")
	h.runJob(job.ID)

	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"job_id":"%s"}`, job.ID)
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
