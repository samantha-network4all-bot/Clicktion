package api

import (
	"encoding/json"
	"net/http"

	"github.com/clicktion/service/internal/llm"
)

// agentTurn runs one tool-enabled LLM turn for the browser agent. Orchestration
// (executing tool calls against the WebView, looping) lives in the Mac app; this
// endpoint is a thin, stateless proxy over the configured local model.
func (h *handler) agentTurn(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Messages []llm.AgentMessage `json:"messages"`
		Tools    []llm.Tool         `json:"tools"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	// Browser agent is local-only (privacy).
	model, err := h.db.DefaultModel(true)
	if err != nil || model == nil {
		http.Error(w, "no local model configured", http.StatusServiceUnavailable)
		return
	}

	client := llm.NewClient(model.BaseURL, model.APIKey, model.ModelName)
	turn, err := client.CompleteWithTools(r.Context(), body.Messages, body.Tools)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(turn)
}
