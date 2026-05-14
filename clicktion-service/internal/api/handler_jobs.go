package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/clicktion/service/internal/db"
)

type createJobRequest struct {
	CaptureID   string `json:"capture_id"`
	SkillName   string `json:"skill_name"`
	SkillPrompt string `json:"skill_prompt"`
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
	job, err := h.db.CreateJob(db.Job{
		CaptureID:   req.CaptureID,
		SkillName:   &skillName,
		SkillPrompt: &skillPrompt,
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

	// Check for an active in-memory stream
	if val, ok := activeStreams.Load(id); ok {
		s := val.(*jobStream)
		idx := 0
		ticker := time.NewTicker(50 * time.Millisecond)
		defer ticker.Stop()

		for {
			select {
			case <-r.Context().Done():
				return
			case <-ticker.C:
				tokens, done := s.snapshot()
				for idx < len(tokens) {
					fmt.Fprintf(w, "data: %s\n\n", sseEscape(tokens[idx]))
					idx++
				}
				flusher.Flush()
				if done {
					fmt.Fprintf(w, "data: [DONE]\n\n")
					flusher.Flush()
					return
				}
			}
		}
	}

	// Job already finished — replay completed assistant messages from DB
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
		if m.Role == "assistant" && m.Content != "" {
			// Replay by sending words so the client sees progressive text,
			// matching the feel of a live stream.
			words := strings.Fields(m.Content)
			for i, w2 := range words {
				chunk := w2
				if i < len(words)-1 {
					chunk += " "
				}
				fmt.Fprintf(w, "data: %s\n\n", sseEscape(chunk))
				flusher.Flush()
				time.Sleep(8 * time.Millisecond)
			}
		}
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

	// Re-run the job with updated history
	h.db.UpdateJobStatus(id, "running")
	h.runJob(id)

	jsonOK(w, map[string]string{"status": "queued"})
}

// sseEscape makes a string safe for SSE data fields by escaping newlines.
// SSE uses blank lines as event delimiters, so literal newlines must be
// sent as separate "data:" lines.
func sseEscape(s string) string {
	return strings.ReplaceAll(s, "\n", "\ndata: ")
}

// jsonString kept for JSON API responses (not SSE).
func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}
