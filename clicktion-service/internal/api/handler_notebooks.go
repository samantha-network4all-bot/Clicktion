package api

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/clicktion/service/internal/db"
	"github.com/clicktion/service/internal/skills"
)

// readAll is io.ReadAll, aliased so the handler reads more naturally.
var readAll = io.ReadAll

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

	// POST /notebooks/{id}/delete — remove the notebook + all its captures.
	if strings.HasSuffix(path, "/delete") && r.Method == http.MethodPost {
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/delete")
		h.notebookDelete(w, r, id)
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

	// POST /notebooks/{id}/regenerate — re-run the most recent job, appending
	// a new response cell. Same skill / capture context as before.
	if strings.HasSuffix(path, "/regenerate") && r.Method == http.MethodPost {
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/regenerate")
		h.notebookRegenerate(w, r, id)
		return
	}

	// POST /notebooks/{id}/edit-ocr — update the OCR text of a capture cell.
	// Body: { capture_id, ocr_text }. Used by P2.4 inline editor.
	if strings.HasSuffix(path, "/edit-ocr") && r.Method == http.MethodPost {
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/edit-ocr")
		h.notebookEditOCR(w, r, id)
		return
	}

	// POST /notebooks/{id}/add-capture — multipart image upload, appended as
	// a new capture cell to an existing notebook (P3.2).
	if strings.HasSuffix(path, "/add-capture") && r.Method == http.MethodPost {
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/"), "/add-capture")
		h.notebookAddCapture(w, r, id)
		return
	}

	// /notebooks/{id}/cells[...] — markdown cell CRUD (P3.1)
	if rest, ok := strings.CutPrefix(path, "/"); ok && strings.HasPrefix(rest, "") {
		parts := strings.Split(rest, "/")
		// parts: [notebookID, "cells", ...]
		if len(parts) >= 2 && parts[1] == "cells" {
			notebookID := parts[0]
			if len(parts) == 2 && r.Method == http.MethodPost {
				h.notebookInsertCell(w, r, notebookID)
				return
			}
			if len(parts) == 3 && r.Method == http.MethodPatch {
				h.notebookUpdateCell(w, r, notebookID, parts[2])
				return
			}
			if len(parts) == 3 && r.Method == http.MethodDelete {
				h.notebookDeleteCell(w, r, notebookID, parts[2])
				return
			}
		}
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

// notebookCount returns counts the Mac app uses for menu-bar badges.
// Currently only open todos; could expand to e.g. recent counts later.
func (h *handler) notebookCount(w http.ResponseWriter, r *http.Request) {
	n, err := h.db.OpenTodoCount()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"open_todos":%d}`, n)
}

func (h *handler) markNotebookDone(w http.ResponseWriter, r *http.Request, id string) {
	if err := h.db.MarkNotebookDone(id); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/notebooks/"+id, http.StatusSeeOther)
}

func (h *handler) notebookDelete(w http.ResponseWriter, r *http.Request, id string) {
	imagePaths, err := h.db.DeleteNotebook(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	for _, p := range imagePaths {
		_ = os.Remove(p)
	}
	http.Redirect(w, r, "/archive", http.StatusSeeOther)
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

// notebookAddCapture attaches a second / nth capture to an existing notebook
// via a browser file upload (multipart). The new capture is saved to disk,
// inserted into the captures table, and appended as a capture cell at the
// end of the notebook. OCR is left empty — the user can paste it in via
// the existing edit-OCR flow.
func (h *handler) notebookAddCapture(w http.ResponseWriter, r *http.Request, notebookID string) {
	// 10 MiB cap on uploads is plenty for screenshots.
	if err := r.ParseMultipartForm(10 << 20); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	file, header, err := r.FormFile("image")
	if err != nil {
		http.Error(w, "missing image file", http.StatusBadRequest)
		return
	}
	defer file.Close()

	// Reject anything that isn't an image by extension. PNG/JPG/WebP cover
	// every realistic source (screenshots, phone photos, browser drag-and-drop).
	ext := strings.ToLower(filepath.Ext(header.Filename))
	switch ext {
	case ".png", ".jpg", ".jpeg", ".webp":
	default:
		http.Error(w, "image must be png/jpg/webp", http.StatusBadRequest)
		return
	}

	data, err := readAll(file)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	imagePath, err := h.saveImage(data)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	// Inherit privacy from the existing notebook's primary capture, if any.
	isPrivate := true
	cells, _ := h.db.ListNotebookCells(notebookID)
	for _, c := range cells {
		if c.Kind == db.CellCapture && c.CaptureID != nil {
			if cap, err := h.db.GetCapture(*c.CaptureID); err == nil && cap != nil {
				isPrivate = cap.IsPrivate
				break
			}
		}
	}

	capture, err := h.db.CreateCapture(db.Capture{
		ImagePath: imagePath,
		IsPrivate: isPrivate,
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	if _, err := h.db.AppendCell(db.NotebookCell{
		NotebookID: notebookID,
		Kind:       db.CellCapture,
		CaptureID:  &capture.ID,
	}); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"capture_id":"%s"}`, capture.ID)
}

// notebookInsertCell adds a markdown cell at a chosen position. Body:
// { content, after_position } — the new cell goes at after_position+1.
// If after_position is missing the cell is appended at the end.
func (h *handler) notebookInsertCell(w http.ResponseWriter, r *http.Request, notebookID string) {
	var body struct {
		Content       string `json:"content"`
		AfterPosition *int   `json:"after_position"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	cell := db.NotebookCell{
		NotebookID: notebookID,
		Kind:       db.CellMarkdown,
		Content:    body.Content,
	}
	var saved db.NotebookCell
	var err error
	if body.AfterPosition == nil {
		saved, err = h.db.AppendCell(cell)
	} else {
		saved, err = h.db.InsertCell(cell, *body.AfterPosition+1)
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"id":"%s","position":%d}`, saved.ID, saved.Position)
}

// notebookUpdateCell rewrites the content of an existing cell. Permission
// check: the cell must belong to the given notebook.
func (h *handler) notebookUpdateCell(w http.ResponseWriter, r *http.Request, notebookID, cellID string) {
	cell, err := h.db.GetCell(cellID)
	if err != nil || cell == nil || cell.NotebookID != notebookID {
		http.Error(w, "cell not found", http.StatusNotFound)
		return
	}
	if cell.Kind != db.CellMarkdown {
		http.Error(w, "only markdown cells can be edited", http.StatusBadRequest)
		return
	}
	var body struct {
		Content string `json:"content"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := h.db.UpdateCellContent(cellID, body.Content); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// notebookDeleteCell removes a cell after a notebook-scope permission check.
// Capture cells are protected (you'd lose your screenshot reference).
func (h *handler) notebookDeleteCell(w http.ResponseWriter, r *http.Request, notebookID, cellID string) {
	cell, err := h.db.GetCell(cellID)
	if err != nil || cell == nil || cell.NotebookID != notebookID {
		http.Error(w, "cell not found", http.StatusNotFound)
		return
	}
	if cell.Kind == db.CellCapture {
		http.Error(w, "capture cells cannot be deleted — delete the notebook instead", http.StatusBadRequest)
		return
	}
	if err := h.db.DeleteCell(cellID); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// notebookEditOCR updates a capture's OCR text after the user manually
// corrects what Vision recognised. The browser typically follows up with a
// Regenerate call so the LLM can re-run against the fixed text.
func (h *handler) notebookEditOCR(w http.ResponseWriter, r *http.Request, notebookID string) {
	var body struct {
		CaptureID string `json:"capture_id"`
		OCRText   string `json:"ocr_text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if body.CaptureID == "" {
		http.Error(w, "capture_id required", http.StatusBadRequest)
		return
	}

	// Verify the capture really belongs to this notebook to prevent cross-
	// notebook edits via a forged capture_id.
	cells, err := h.db.ListNotebookCells(notebookID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	allowed := false
	for _, c := range cells {
		if c.Kind == db.CellCapture && c.CaptureID != nil && *c.CaptureID == body.CaptureID {
			allowed = true
			break
		}
	}
	if !allowed {
		http.Error(w, "capture not in this notebook", http.StatusBadRequest)
		return
	}

	if err := h.db.UpdateCapture(body.CaptureID, map[string]any{"ocr_text": body.OCRText}); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// notebookRegenerate re-runs the latest job on a notebook without adding a
// user message. Used by the "Regenerate" button on the most recent response
// cell — produces a new response variant with the same skill + context.
func (h *handler) notebookRegenerate(w http.ResponseWriter, r *http.Request, notebookID string) {
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
		http.Error(w, "no job to regenerate — pick a skill first", http.StatusBadRequest)
		return
	}

	h.db.UpdateJobStatus(jobID, "running")
	h.runJob(jobID)

	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, `{"job_id":"%s"}`, jobID)
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
