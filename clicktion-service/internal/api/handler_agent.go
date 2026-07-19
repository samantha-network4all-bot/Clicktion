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

// agentVision answers a question about a screenshot using a (vision-capable)
// model. Uses the given model_id, or the local default when omitted.
func (h *handler) agentVision(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Image    string `json:"image"`     // base64 PNG
		Question string `json:"question"`
		ModelID  string `json:"model_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if body.Image == "" {
		http.Error(w, "missing image", http.StatusBadRequest)
		return
	}

	var baseURL, apiKey, modelName string
	if body.ModelID != "" {
		m, err := h.db.GetModel(body.ModelID)
		if err != nil || m == nil {
			http.Error(w, "model not found", http.StatusBadRequest)
			return
		}
		baseURL, apiKey, modelName = m.BaseURL, m.APIKey, m.ModelName
	} else {
		m, err := h.db.DefaultModel(true)
		if err != nil || m == nil {
			http.Error(w, "no local model configured", http.StatusServiceUnavailable)
			return
		}
		baseURL, apiKey, modelName = m.BaseURL, m.APIKey, m.ModelName
	}

	question := body.Question
	if question == "" {
		question = "Describe this web page and where the key interactive elements are."
	}

	client := llm.NewClient(baseURL, apiKey, modelName)
	text, err := client.CompleteVision(r.Context(), question, body.Image, 512)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"text": text})
}
