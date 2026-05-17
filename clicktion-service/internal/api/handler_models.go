package api

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/clicktion/service/internal/db"
	"github.com/clicktion/service/internal/llm"
)

type modelJSON struct {
	ID              string  `json:"id,omitempty"`
	Name            string  `json:"name"`
	BaseURL         string  `json:"base_url"`
	APIKey          string  `json:"api_key"`
	ModelName       string  `json:"model_name"`
	IsLocal         bool    `json:"is_local"`
	IsLocalOverride *bool   `json:"is_local_override,omitempty"`
	IsDefault       bool    `json:"is_default"`
	FallbackOrder   int     `json:"fallback_order"`
}

func modelToJSON(m db.Model) modelJSON {
	return modelJSON{
		ID: m.ID, Name: m.Name, BaseURL: m.BaseURL,
		APIKey: m.APIKey, ModelName: m.ModelName,
		IsLocal: m.IsLocal, IsLocalOverride: m.IsLocalOverride,
		IsDefault: m.IsDefault, FallbackOrder: m.FallbackOrder,
	}
}

func jsonToModel(j modelJSON) db.Model {
	return db.Model{
		ID: j.ID, Name: j.Name, BaseURL: j.BaseURL,
		APIKey: j.APIKey, ModelName: j.ModelName,
		IsLocal: j.IsLocal, IsLocalOverride: j.IsLocalOverride,
		IsDefault: j.IsDefault, FallbackOrder: j.FallbackOrder,
	}
}

func (h *handler) listModels(w http.ResponseWriter, r *http.Request) {
	models, err := h.db.ListModels()
	if err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	out := make([]modelJSON, len(models))
	for i, m := range models {
		out[i] = modelToJSON(m)
	}
	jsonOK(w, out)
}

func (h *handler) createModel(w http.ResponseWriter, r *http.Request) {
	var j modelJSON
	if err := json.NewDecoder(r.Body).Decode(&j); err != nil {
		httpError(w, err, http.StatusBadRequest)
		return
	}
	// Auto-classify local if not overridden
	if j.IsLocalOverride == nil {
		j.IsLocal = db.ClassifyLocal(j.BaseURL)
	}
	created, err := h.db.CreateModel(jsonToModel(j))
	if err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusCreated)
	jsonOK(w, modelToJSON(created))
}

func (h *handler) updateModel(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var j modelJSON
	if err := json.NewDecoder(r.Body).Decode(&j); err != nil {
		httpError(w, err, http.StatusBadRequest)
		return
	}
	j.ID = id
	if j.IsLocalOverride == nil {
		j.IsLocal = db.ClassifyLocal(j.BaseURL)
	}
	if j.IsDefault {
		if err := h.db.SetDefaultModel(id); err != nil {
			httpError(w, err, http.StatusInternalServerError)
			return
		}
	}
	if err := h.db.UpdateModel(jsonToModel(j)); err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	jsonOK(w, j)
}

func (h *handler) deleteModel(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := h.db.DeleteModel(id); err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *handler) testModel(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	model, err := h.db.GetModel(id)
	if err != nil {
		httpError(w, err, http.StatusNotFound)
		return
	}

	client := llm.NewClient(model.BaseURL, model.APIKey, model.ModelName)
	start := time.Now()

	// Send a tiny vision-compatible test message
	resp, err := client.Complete(r.Context(), []llm.Message{
		llm.TextMessage(llm.RoleUser, "Reply with the single word: ready"),
	})

	type testResult struct {
		Success   bool   `json:"success"`
		Response  string `json:"response,omitempty"`
		LatencyMs int    `json:"latency_ms"`
		Error     string `json:"error,omitempty"`
	}

	ms := int(time.Since(start).Milliseconds())
	if err != nil {
		jsonOK(w, testResult{Success: false, LatencyMs: ms, Error: err.Error()})
		return
	}
	jsonOK(w, testResult{Success: true, Response: resp, LatencyMs: ms})
}
