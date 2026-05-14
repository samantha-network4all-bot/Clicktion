package api

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/clicktion/service/internal/db"
	"github.com/clicktion/service/internal/llm"
)

func (h *handler) serveAdmin(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/admin")
	if path == "" {
		path = "/"
	}

	switch {
	case path == "/" || path == "":
		h.adminDash(w, r)

	// Models
	case path == "/models" && r.Method == http.MethodGet:
		h.adminModels(w, r)
	case path == "/models/new" && r.Method == http.MethodGet:
		h.adminModelNew(w, r)
	case path == "/models/new" && r.Method == http.MethodPost:
		h.adminModelCreate(w, r)
	case strings.HasSuffix(path, "/edit") && r.Method == http.MethodGet:
		h.adminModelEdit(w, r, modelID(path, "/edit"))
	case strings.HasSuffix(path, "/edit") && r.Method == http.MethodPost:
		h.adminModelUpdate(w, r, modelID(path, "/edit"))
	case strings.HasSuffix(path, "/delete") && r.Method == http.MethodPost:
		h.adminModelDelete(w, r, modelID(path, "/delete"))
	case strings.HasSuffix(path, "/test") && r.Method == http.MethodPost:
		h.adminModelTest(w, r, modelID(path, "/test"))
	case strings.HasSuffix(path, "/setdefault") && r.Method == http.MethodPost:
		h.adminModelSetDefault(w, r, modelID(path, "/setdefault"))

	// API keys
	case path == "/keys" && r.Method == http.MethodGet:
		h.adminKeys(w, r)
	case path == "/keys" && r.Method == http.MethodPost:
		h.adminKeyCreate(w, r)
	case strings.HasSuffix(path, "/delete") && strings.Contains(path, "/keys/") && r.Method == http.MethodPost:
		h.adminKeyDelete(w, r, keyID(path))

	// Storage
	case path == "/storage" && r.Method == http.MethodGet:
		h.adminStorage(w, r)
	case path == "/storage/cleanup" && r.Method == http.MethodPost:
		h.adminStorageCleanup(w, r)

	default:
		http.NotFound(w, r)
	}
}

// MARK: - Dashboard

type adminDashData struct {
	Stats   db.StorageStats
	Models  []db.Model
	LLMStat []db.LLMStat
	Logs    []db.LLMLogEntry
	Msg     string
}

func (h *handler) adminDash(w http.ResponseWriter, r *http.Request) {
	models, _ := h.db.ListModels()
	stats := h.db.StorageStats(filepath.Join(h.dataDir, "captures"))
	llmStats, _ := h.db.LLMStats()
	logs, _ := h.db.RecentLLMLogs(10)
	renderTemplate(w, adminDashTmpl, "admin.html", adminDashData{
		Stats:   stats,
		Models:  models,
		LLMStat: llmStats,
		Logs:    logs,
		Msg:     r.URL.Query().Get("msg"),
	})
}

// MARK: - Models

type adminModelsData struct {
	Models []db.Model
	Msg    string
	TestID string
	TestOK bool
	TestMs int
	TestResp string
}

func (h *handler) adminModels(w http.ResponseWriter, r *http.Request) {
	models, _ := h.db.ListModels()
	q := r.URL.Query()
	renderTemplate(w, adminModelsTmpl, "admin_models.html", adminModelsData{
		Models:   models,
		Msg:      q.Get("msg"),
		TestID:   q.Get("test_id"),
		TestOK:   q.Get("test_ok") == "1",
		TestMs:   atoi(q.Get("test_ms")),
		TestResp: q.Get("test_resp"),
	})
}

type adminModelFormData struct {
	Model  db.Model
	IsNew  bool
	Errors map[string]string
	Msg    string
}

func (h *handler) adminModelNew(w http.ResponseWriter, r *http.Request) {
	renderTemplate(w, adminModelFormTmpl, "admin_model_form.html", adminModelFormData{
		IsNew: true,
		Model: db.Model{FallbackOrder: 10},
	})
}

func (h *handler) adminModelCreate(w http.ResponseWriter, r *http.Request) {
	m := modelFromForm(r)
	if _, err := h.db.CreateModel(m); err != nil {
		renderTemplate(w, adminModelFormTmpl, "admin_model_form.html", adminModelFormData{
			IsNew: true, Model: m,
			Errors: map[string]string{"_": err.Error()},
		})
		return
	}
	redirect(w, r, "/admin/models?msg=Model+created")
}

func (h *handler) adminModelEdit(w http.ResponseWriter, r *http.Request, id string) {
	m, err := h.db.GetModel(id)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	renderTemplate(w, adminModelFormTmpl, "admin_model_form.html", adminModelFormData{Model: *m})
}

func (h *handler) adminModelUpdate(w http.ResponseWriter, r *http.Request, id string) {
	m := modelFromForm(r)
	m.ID = id
	if err := h.db.UpdateModel(m); err != nil {
		renderTemplate(w, adminModelFormTmpl, "admin_model_form.html", adminModelFormData{
			Model:  m,
			Errors: map[string]string{"_": err.Error()},
		})
		return
	}
	redirect(w, r, "/admin/models?msg=Model+updated")
}

func (h *handler) adminModelDelete(w http.ResponseWriter, r *http.Request, id string) {
	h.db.DeleteModel(id)
	redirect(w, r, "/admin/models?msg=Model+deleted")
}

func (h *handler) adminModelTest(w http.ResponseWriter, r *http.Request, id string) {
	m, err := h.db.GetModel(id)
	if err != nil {
		redirect(w, r, "/admin/models?msg=Model+not+found")
		return
	}
	client := llm.NewClient(m.BaseURL, m.APIKey, m.ModelName)
	start := time.Now()
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	resp, err := client.Complete(ctx, []llm.Message{
		llm.TextMessage(llm.RoleUser, "Reply with the single word: ready"),
	})
	ms := int(time.Since(start).Milliseconds())
	if err != nil {
		redirect(w, r, fmt.Sprintf("/admin/models?test_id=%s&test_ok=0&test_ms=%d&msg=%s",
			id, ms, urlEncode("Test failed: "+err.Error())))
		return
	}
	redirect(w, r, fmt.Sprintf("/admin/models?test_id=%s&test_ok=1&test_ms=%d&test_resp=%s",
		id, ms, urlEncode(resp)))
}

func (h *handler) adminModelSetDefault(w http.ResponseWriter, r *http.Request, id string) {
	// Clear existing default, set new one
	models, _ := h.db.ListModels()
	for _, m := range models {
		m.IsDefault = m.ID == id
		h.db.UpdateModel(m)
	}
	redirect(w, r, "/admin/models?msg=Default+model+updated")
}

// MARK: - API Keys

type adminKeysData struct {
	Keys []db.APIKey
	Msg  string
}

func (h *handler) adminKeys(w http.ResponseWriter, r *http.Request) {
	keys, _ := h.db.ListAPIKeys()
	renderTemplate(w, adminKeysTmpl, "admin_keys.html", adminKeysData{
		Keys: keys,
		Msg:  r.URL.Query().Get("msg"),
	})
}

type adminKeyCreatedData struct {
	Label     string
	Plaintext string
}

func (h *handler) adminKeyCreate(w http.ResponseWriter, r *http.Request) {
	r.ParseForm()
	label := strings.TrimSpace(r.FormValue("label"))
	if label == "" {
		label = "key-" + time.Now().Format("20060102")
	}
	plaintext, err := h.db.CreateAPIKey(label)
	if err != nil {
		redirect(w, r, "/admin/keys?msg="+urlEncode("Error: "+err.Error()))
		return
	}
	renderTemplate(w, adminKeyCreatedTmpl, "admin_key_created.html", adminKeyCreatedData{
		Label:     label,
		Plaintext: plaintext,
	})
}

func (h *handler) adminKeyDelete(w http.ResponseWriter, r *http.Request, id string) {
	h.db.DeleteAPIKey(id)
	redirect(w, r, "/admin/keys?msg=Key+deleted")
}

// MARK: - Storage

type adminStorageData struct {
	Stats    db.StorageStats
	LLMStats []db.LLMStat
	Msg      string
}

func (h *handler) adminStorage(w http.ResponseWriter, r *http.Request) {
	stats := h.db.StorageStats(filepath.Join(h.dataDir, "captures"))
	llmStats, _ := h.db.LLMStats()
	renderTemplate(w, adminStorageTmpl, "admin_storage.html", adminStorageData{
		Stats:    stats,
		LLMStats: llmStats,
		Msg:      r.URL.Query().Get("msg"),
	})
}

func (h *handler) adminStorageCleanup(w http.ResponseWriter, r *http.Request) {
	r.ParseForm()
	days := atoi(r.FormValue("days"))
	if days < 1 {
		days = 30
	}
	cutoff := time.Now().AddDate(0, 0, -days)

	// Collect image paths before deletion
	captures, _, _ := h.db.SearchCaptures(db.ArchiveFilter{Limit: 9999})
	var toDelete []string
	for _, c := range captures {
		if c.CreatedAt.Before(cutoff) && c.ImagePath != "" {
			toDelete = append(toDelete, c.ImagePath)
		}
	}

	n, err := h.db.DeleteCapturesBefore(cutoff)
	if err != nil {
		redirect(w, r, "/admin/storage?msg="+urlEncode("Error: "+err.Error()))
		return
	}
	// Remove image files
	for _, p := range toDelete {
		os.Remove(p)
	}
	redirect(w, r, fmt.Sprintf("/admin/storage?msg=%s",
		urlEncode(fmt.Sprintf("Deleted %d captures older than %d days", n, days))))
}

// MARK: - Helpers

func modelFromForm(r *http.Request) db.Model {
	r.ParseForm()
	fo := atoi(r.FormValue("fallback_order"))
	m := db.Model{
		Name:          r.FormValue("name"),
		BaseURL:       r.FormValue("base_url"),
		APIKey:        r.FormValue("api_key"),
		ModelName:     r.FormValue("model_name"),
		IsDefault:     r.FormValue("is_default") == "on",
		FallbackOrder: fo,
	}
	override := r.FormValue("local_override")
	switch override {
	case "local":
		t := true
		m.IsLocalOverride = &t
		m.IsLocal = true
	case "remote":
		f := false
		m.IsLocalOverride = &f
		m.IsLocal = false
	default:
		m.IsLocal = db.ClassifyLocal(m.BaseURL)
	}
	return m
}

func modelID(path, suffix string) string {
	path = strings.TrimPrefix(path, "/models/")
	return strings.TrimSuffix(path, suffix)
}

func keyID(path string) string {
	path = strings.TrimPrefix(path, "/keys/")
	return strings.TrimSuffix(path, "/delete")
}

func atoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

func urlEncode(s string) string {
	return strings.ReplaceAll(s, " ", "+")
}
