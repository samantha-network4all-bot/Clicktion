package api

import (
	"encoding/json"
	"fmt"
	"net/http"
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

	// Store the initial user message — the capture context is the implicit first message
	if req.SkillName != "" {
		h.db.AddChatMessage(db.ChatMessage{
			CaptureID: req.CaptureID,
			Role:      "system",
			Content:   "Skill: " + req.SkillName,
		})
	}

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
					fmt.Fprintf(w, "data: %s\n\n", tokens[idx])
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
		if m.Role == "assistant" {
			// Send content character by character is unnecessary — send as one token
			fmt.Fprintf(w, "data: %s\n\n", jsonString(m.Content))
			flusher.Flush()
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

// jsonString returns a JSON-encoded string for embedding in SSE data fields
func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}
