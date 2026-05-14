package api

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/clicktion/service/internal/db"
	"github.com/clicktion/service/internal/llm"
)

type capturePayload struct {
	ImageBase64 string          `json:"image_base64"`
	OCRText     string          `json:"ocr_text"`
	AppName     *string         `json:"app_name"`
	WindowTitle *string         `json:"window_title"`
	IsPrivate   bool            `json:"is_private"`
	SkillHint   *string         `json:"skill_hint"`
	Skills      []llm.SkillInfo `json:"available_skills"`
}

type captureResponse struct {
	ID            string  `json:"id"`
	SuggestedSkill *string `json:"suggested_skill"`
}

func (h *handler) createCapture(w http.ResponseWriter, r *http.Request) {
	var p capturePayload
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		httpError(w, err, http.StatusBadRequest)
		return
	}

	// Decode and save image
	imgData, err := base64.StdEncoding.DecodeString(p.ImageBase64)
	if err != nil {
		httpError(w, fmt.Errorf("invalid image_base64"), http.StatusBadRequest)
		return
	}
	imagePath, err := h.saveImage(imgData)
	if err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}

	// Persist capture
	capture, err := h.db.CreateCapture(db.Capture{
		ImagePath:   imagePath,
		OCRText:     p.OCRText,
		AppName:     p.AppName,
		WindowTitle: p.WindowTitle,
		IsPrivate:   p.IsPrivate,
	})
	if err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}

	// Pre-select skill asynchronously (fast non-streaming call)
	var suggested *string
	if len(p.Skills) > 0 {
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()

		model, err := h.db.DefaultModel(p.IsPrivate)
		if err == nil {
			client := llm.NewClient(model.BaseURL, model.APIKey, model.ModelName)
			appName := ""
			winTitle := ""
			if p.AppName != nil {
				appName = *p.AppName
			}
			if p.WindowTitle != nil {
				winTitle = *p.WindowTitle
			}
			name := llm.SelectSkill(ctx, client, p.Skills, appName, winTitle, p.OCRText)
			if name != "" {
				suggested = &name
			}
		}
	}

	jsonOK(w, captureResponse{ID: capture.ID, SuggestedSkill: suggested})
}

func (h *handler) listCaptures(w http.ResponseWriter, r *http.Request) {
	limit := 50
	offset := 0
	if l := r.URL.Query().Get("limit"); l != "" {
		if v, err := strconv.Atoi(l); err == nil {
			limit = v
		}
	}
	if o := r.URL.Query().Get("offset"); o != "" {
		if v, err := strconv.Atoi(o); err == nil {
			offset = v
		}
	}
	captures, err := h.db.ListCaptures(limit, offset)
	if err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	jsonOK(w, captures)
}

func (h *handler) getCapture(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	c, err := h.db.GetCapture(id)
	if err != nil {
		httpError(w, err, http.StatusNotFound)
		return
	}
	jsonOK(w, c)
}

func (h *handler) updateCapture(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var fields map[string]any
	if err := json.NewDecoder(r.Body).Decode(&fields); err != nil {
		httpError(w, err, http.StatusBadRequest)
		return
	}
	if err := h.db.UpdateCapture(id, fields); err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	jsonOK(w, map[string]string{"status": "updated"})
}

func (h *handler) deleteCapture(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	// Get image path before deleting
	c, err := h.db.GetCapture(id)
	if err == nil && c.ImagePath != "" {
		os.Remove(c.ImagePath)
	}
	if err := h.db.DeleteCapture(id); err != nil {
		httpError(w, err, http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *handler) saveImage(data []byte) (string, error) {
	dir := filepath.Join(h.dataDir, "captures")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	name := fmt.Sprintf("%d.png", time.Now().UnixNano())
	path := filepath.Join(dir, name)
	return path, os.WriteFile(path, data, 0o600)
}
