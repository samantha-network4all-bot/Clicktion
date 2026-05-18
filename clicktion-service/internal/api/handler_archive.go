package api

import (
	"fmt"
	"html/template"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/clicktion/service/internal/db"
)

// staticWebFS is defined in templates.go


// MARK: - Archive index

type archivePage struct {
	Captures []db.ArchiveCapture
	Stats    db.StorageStats
	Skills   []string
	Filter   db.ArchiveFilter
	Total    int
	Pages    int
}

func (h *handler) serveArchive(w http.ResponseWriter, r *http.Request) {
	// Route sub-paths
	path := strings.TrimPrefix(r.URL.Path, "/archive")
	switch {
	case path == "" || path == "/":
		h.archiveIndex(w, r)
	case strings.HasPrefix(path, "/images/"):
		h.serveImage(w, r, strings.TrimPrefix(path, "/images/"))
	case strings.HasSuffix(path, "/delete") && r.Method == http.MethodPost:
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/captures/"), "/delete")
		h.archiveDelete(w, r, id)
	case strings.HasPrefix(path, "/captures/"):
		id := strings.TrimPrefix(path, "/captures/")
		h.archiveCapture(w, r, id)
	default:
		http.NotFound(w, r)
	}
}

func (h *handler) archiveIndex(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	filter := db.ArchiveFilter{
		Query:    q.Get("q"),
		Todo:     q.Get("filter") == "todo",
		Public:   q.Get("filter") == "public",
		Skill:    q.Get("skill"),
		DateFrom: q.Get("from"),
		DateTo:   q.Get("to"),
		OrderBy:  q.Get("order"),
		Limit:    48,
	}
	if p, err := strconv.Atoi(q.Get("page")); err == nil && p > 0 {
		filter.Page = p
	}

	captures, total, err := h.db.SearchCaptures(filter)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	skills, _ := h.db.DistinctSkills()
	stats := h.db.StorageStats(filepath.Join(h.dataDir, "captures"))

	pages := (total + filter.Limit - 1) / filter.Limit
	if pages < 1 {
		pages = 1
	}

	renderTemplate(w, archiveIndexTmpl, "archive.html", archivePage{
		Captures: captures,
		Stats:    stats,
		Skills:   skills,
		Filter:   filter,
		Total:    total,
		Pages:    pages,
	})
}

// MARK: - Capture detail

type capturePage struct {
	Capture  *db.Capture
	Messages []db.ChatMessage
}

func (h *handler) archiveCapture(w http.ResponseWriter, r *http.Request, id string) {
	// Forward the legacy capture-detail URL to the new notebook view.
	// /archive/captures/{captureID} → /notebooks/{notebookID}
	if nb, err := h.db.NotebookForCapture(id); err == nil && nb != nil {
		http.Redirect(w, r, "/notebooks/"+nb.ID, http.StatusMovedPermanently)
		return
	}
	// Fallback (notebook missing for some reason): render the old page.
	capture, err := h.db.GetCapture(id)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	messages, err := h.db.ListChatMessages(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	renderTemplate(w, archiveCaptureTmpl, "capture.html", capturePage{Capture: capture, Messages: messages})
}

// MARK: - Delete

func (h *handler) archiveDelete(w http.ResponseWriter, r *http.Request, id string) {
	c, err := h.db.GetCapture(id)
	if err == nil && c.ImagePath != "" {
		os.Remove(c.ImagePath)
	}
	h.db.DeleteCapture(id)
	http.Redirect(w, r, "/archive", http.StatusSeeOther)
}

// MARK: - Image serving

func (h *handler) serveImage(w http.ResponseWriter, r *http.Request, id string) {
	capture, err := h.db.GetCapture(id)
	if err != nil || capture.ImagePath == "" {
		http.NotFound(w, r)
		return
	}
	data, err := os.ReadFile(capture.ImagePath)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "private, max-age=3600")
	w.Write(data)
}

// MARK: - Static files

func (h *handler) serveStatic(w http.ResponseWriter, r *http.Request) {
	http.FileServer(http.FS(staticWebFS)).ServeHTTP(w, r)
}

func timeAgo(t time.Time) string {
	d := time.Since(t)
	switch {
	case d < time.Minute:
		return "just now"
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh ago", int(d.Hours()))
	case d < 7*24*time.Hour:
		return fmt.Sprintf("%dd ago", int(d.Hours()/24))
	default:
		return t.Format("2 Jan 2006")
	}
}

func renderContent(s string) template.HTML {
	var out strings.Builder
	rest := s
	fence := "```"
	for {
		idx := strings.Index(rest, fence)
		if idx < 0 {
			out.WriteString(template.HTMLEscapeString(rest))
			break
		}
		out.WriteString(template.HTMLEscapeString(rest[:idx]))
		after := rest[idx+3:]
		end := strings.Index(after, fence)
		if end < 0 {
			out.WriteString(template.HTMLEscapeString(rest[idx:]))
			break
		}
		code := after[:end]
		// Strip optional language tag on first line
		if nl := strings.Index(code, "\n"); nl >= 0 {
			code = code[nl+1:]
		}
		out.WriteString("<pre>")
		out.WriteString(template.HTMLEscapeString(strings.TrimSpace(code)))
		out.WriteString("</pre>")
		rest = after[end+3:]
	}
	return template.HTML(out.String())
}

func truncate(s string, n int) string {
	s = strings.ReplaceAll(s, "\n", " ")
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
