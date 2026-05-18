package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/clicktion/service/internal/db"
)

type createJobRequest struct {
	CaptureID      string   `json:"capture_id"`
	SkillName      string   `json:"skill_name"`
	SkillPrompt    string   `json:"skill_prompt"`
	SendImage      *bool    `json:"send_image"` // nil → default true (backward compat)
	SendOCR        *bool    `json:"send_ocr"`   // nil → default true
	MasterPrompt   string   `json:"master_prompt"`
	Temperature    *float64 `json:"temperature"`    // nil or -1 → model default
	MaxTokens      *int     `json:"max_tokens"`     // nil or 0 → model default
	ThinkingEnabled bool    `json:"thinking_enabled"`
	Fresh          bool     `json:"fresh"`          // clear chat history before running (skill switch)
}

type jobResponse struct {
	ID string `json:"id"`
}

func (h *handler) createJob(w http.ResponseWriter, r *http.Request) {
	var req createJobRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpError(w, err, http.StatusBadRequest)
		return
	}
	if req.CaptureID == "" {
		httpError(w, fmt.Errorf("capture_id required"), http.StatusBadRequest)
		return
	}

	// Do NOT pre-populate chat_messages here. buildMessages checks len(history)==0
	// to decide whether to inject the screenshot + OCR context as the first user
	// message. Any message written here would flip that check and skip the image.
	// The skill name and prompt are stored on the job record itself.

	skillName := req.SkillName
	skillPrompt := req.SkillPrompt
	sendImage := req.SendImage == nil || *req.SendImage // default true
	sendOCR := req.SendOCR == nil || *req.SendOCR       // default true

	var temperature float64 = -1 // -1 = model default
	if req.Temperature != nil && *req.Temperature >= 0 {
		temperature = *req.Temperature
	}
	maxTokens := 0
	if req.MaxTokens != nil && *req.MaxTokens > 0 {
		maxTokens = *req.MaxTokens
	}

	if req.Fresh {
		_ = h.db.DeleteChatMessages(req.CaptureID)
	}

	job, err := h.db.CreateJob(db.Job{
		CaptureID:      req.CaptureID,
		SkillName:      &skillName,
		SkillPrompt:    &skillPrompt,
		SendImage:      sendImage,
		SendOCR:        sendOCR,
		MasterPrompt:   req.MasterPrompt,
		Temperature:    temperature,
		MaxTokens:      maxTokens,
		ThinkingEnabled: req.ThinkingEnabled,
	})
	if err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}

	// Kick off LLM execution in a goroutine
	h.db.UpdateJobStatus(job.ID, "running")
	h.runJob(job.ID)

	w.WriteHeader(http.StatusCreated)
	jsonOK(w, jobResponse{ID: job.ID})
}

// streamJob delivers tokens via Server-Sent Events.
// It polls the in-memory jobStream every 50ms, flushing tokens to the client.
// If the job is already finished, it replays messages from the DB.
func (h *handler) streamJob(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")

	flusher, ok := w.(http.Flusher)
	if !ok {
		httpError(w, fmt.Errorf("streaming not supported"), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	// Check for an active in-memory stream — read from channel immediately as tokens arrive.
	if val, ok := activeStreams.Load(id); ok {
		s := val.(*jobStream)
		ctx := r.Context()
		for {
			select {
			case <-ctx.Done():
				return
			case token, ok := <-s.ch:
				if !ok {
					// Channel closed — stream finished
					fmt.Fprintf(w, "data: [DONE]\n\n")
					flusher.Flush()
					return
				}
				fmt.Fprintf(w, "data: %s\n\n", sseEscape(token))
				flusher.Flush()
			}
		}
	}

	// Job already finished (no active stream found) — replay from DB word by word
	// so the Swift client receives many tokens rather than one giant block.
	job, err := h.db.GetJob(id)
	if err != nil {
		httpError(w, err, http.StatusNotFound)
		return
	}
	messages, err := h.db.ListChatMessages(job.CaptureID)
	if err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	for _, m := range messages {
		if m.Role != "assistant" || m.Content == "" {
			continue
		}
		// Split on spaces so each word arrives as a separate SSE event,
		// giving the Swift client the same token-by-token experience as a live stream.
		words := strings.Fields(m.Content)
		for i, word := range words {
			token := word
			if i < len(words)-1 {
				token += " "
			}
			fmt.Fprintf(w, "data: %s\n\n", sseEscape(token))
			flusher.Flush()
		}
		// Preserve paragraph breaks between messages
		fmt.Fprintf(w, "data: \n\n")
		flusher.Flush()
	}
	fmt.Fprintf(w, "data: [DONE]\n\n")
	flusher.Flush()
}

func (h *handler) sendMessage(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")

	var body struct {
		Message string `json:"message"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		httpError(w, err, http.StatusBadRequest)
		return
	}

	job, err := h.db.GetJob(id)
	if err != nil {
		httpError(w, err, http.StatusNotFound)
		return
	}

	// Persist user message
	h.db.AddChatMessage(db.ChatMessage{
		CaptureID: job.CaptureID,
		Role:      "user",
		Content:   body.Message,
	})
	// Mirror into the notebook as a markdown cell (user input shows up
	// between response cells like in Jupyter).
	h.db.AppendCellByCapture(job.CaptureID, db.NotebookCell{
		Kind:    db.CellMarkdown,
		Content: body.Message,
	})

	// Re-run the job with updated history
	h.db.UpdateJobStatus(id, "running")
	h.runJob(id)

	jsonOK(w, map[string]string{"status": "queued"})
}

// sseEscape makes a string safe for SSE data fields by replacing newlines
// with the multi-line SSE continuation sequence.
func sseEscape(s string) string {
	return strings.ReplaceAll(s, "\n", "\ndata: ")
}

