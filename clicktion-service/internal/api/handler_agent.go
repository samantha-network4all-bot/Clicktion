package api

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/clicktion/service/internal/llm"
)

// agentTurn runs one tool-enabled LLM turn for the browser agent. Orchestration
// (executing tool calls against the WebView, looping) lives in the Mac app; this
// endpoint is a thin, stateless proxy over the configured local model.
// resolveModelClient returns an LLM client and the model's name for the given
// id, or the local default when id is empty. Writes an HTTP error and returns
// nil on failure.
func (h *handler) resolveModelClient(w http.ResponseWriter, id string) (*llm.Client, string) {
	if id != "" {
		m, err := h.db.GetModel(id)
		if err != nil || m == nil {
			http.Error(w, "model not found", http.StatusBadRequest)
			return nil, ""
		}
		return llm.NewClient(m.BaseURL, m.APIKey, m.ModelName), m.ModelName
	}
	m, err := h.db.DefaultModel(true)
	if err != nil || m == nil {
		http.Error(w, "no local model configured", http.StatusServiceUnavailable)
		return nil, ""
	}
	return llm.NewClient(m.BaseURL, m.APIKey, m.ModelName), m.ModelName
}

func (h *handler) agentTurn(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Messages []llm.AgentMessage `json:"messages"`
		Tools    []llm.Tool         `json:"tools"`
		ModelID  string             `json:"model_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	client, modelName := h.resolveModelClient(w, body.ModelID)
	if client == nil {
		return
	}
	start := time.Now()
	turn, err := client.CompleteWithTools(r.Context(), body.Messages, body.Tools)
	ms := time.Since(start).Milliseconds()
	if err != nil {
		log.Printf("agent/turn model=%s messages=%d FAILED after %dms: %v",
			modelName, len(body.Messages), ms, err)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	if len(turn.ToolCalls) == 0 {
		preview := turn.Content
		if len(preview) > 120 {
			preview = preview[:120]
		}
		log.Printf("agent/turn model=%s messages=%d -> no tool calls (text: %q) in %dms",
			modelName, len(body.Messages), preview, ms)
	} else {
		var calls []string
		for _, tc := range turn.ToolCalls {
			args := tc.Function.Arguments
			if len(args) > 100 {
				args = args[:100]
			}
			calls = append(calls, tc.Function.Name+" "+args)
		}
		log.Printf("agent/turn model=%s messages=%d -> [%s] in %dms",
			modelName, len(body.Messages), strings.Join(calls, "; "), ms)
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

	client, modelName := h.resolveModelClient(w, body.ModelID)
	if client == nil {
		return
	}

	question := body.Question
	if question == "" {
		question = "Describe this web page and where the key interactive elements are."
	}

	start := time.Now()
	text, err := client.CompleteVision(r.Context(), question, body.Image, 512)
	ms := time.Since(start).Milliseconds()
	if err != nil {
		log.Printf("agent/vision model=%s FAILED after %dms: %v", modelName, ms, err)
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	log.Printf("agent/vision model=%s -> %d chars in %dms", modelName, len(text), ms)

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"text": text})
}
