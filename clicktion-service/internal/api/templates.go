package api

import (
	"html/template"
	"io/fs"
	"net/http"

	clickweb "github.com/clicktion/service/web"
)

// Each page is its own template set (base.html + page.html) to avoid
// {{define}} block name collisions across pages.
var (
	archiveIndexTmpl   *template.Template
	archiveCaptureTmpl *template.Template

	adminDashTmpl        *template.Template
	adminModelsTmpl      *template.Template
	adminModelFormTmpl   *template.Template
	adminKeysTmpl        *template.Template
	adminKeyCreatedTmpl  *template.Template
	adminStorageTmpl     *template.Template
)

var (
	sharedFuncMap template.FuncMap
	staticWebFS   fs.FS // served at /static/
)

func init() {
	sharedFuncMap = template.FuncMap{
		"timeAgo":  timeAgo,
		"truncate": truncate,
		"add":      func(a, b int) int { return a + b },
		"sub":      func(a, b int) int { return a - b },
		"deref":    func(s *string) string { if s == nil { return "" }; return *s },
		"seq": func(start, end int) []int {
			var out []int
			for i := start; i <= end; i++ {
				out = append(out, i)
			}
			return out
		},
		"renderContent": func(s string) template.HTML { return renderContent(s) },
		"classifyLabel": func(isLocal bool, override *bool) string {
			if override != nil {
				if *override {
					return "Local (forced)"
				}
				return "Remote (forced)"
			}
			if isLocal {
				return "Local"
			}
			return "Remote"
		},
		"localOverride": func(b *bool) string {
			if b == nil {
				return "auto"
			}
			if *b {
				return "local"
			}
			return "remote"
		},
		"classifyClass": func(isLocal bool, override *bool) string {
			eff := isLocal
			if override != nil {
				eff = *override
			}
			if eff {
				return "badge badge-private"
			}
			return "badge badge-public"
		},
	}

	tmplFS, _ := fs.Sub(clickweb.FS, "templates")
	staticWebFS, _ = fs.Sub(clickweb.FS, "static")

	parse := func(files ...string) *template.Template {
		return template.Must(
			template.New("").Funcs(sharedFuncMap).ParseFS(tmplFS, files...),
		)
	}

	archiveIndexTmpl   = parse("base.html", "archive.html")
	archiveCaptureTmpl = parse("base.html", "capture.html")

	adminDashTmpl       = parse("base.html", "admin.html")
	adminModelsTmpl     = parse("base.html", "admin_models.html")
	adminModelFormTmpl  = parse("base.html", "admin_model_form.html")
	adminKeysTmpl       = parse("base.html", "admin_keys.html")
	adminKeyCreatedTmpl = parse("base.html", "admin_key_created.html")
	adminStorageTmpl    = parse("base.html", "admin_storage.html")
}

func renderTemplate(w http.ResponseWriter, t *template.Template, name string, data any) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := t.ExecuteTemplate(w, name, data); err != nil {
		println("template error:", err.Error())
	}
}

func redirect(w http.ResponseWriter, r *http.Request, url string) {
	http.Redirect(w, r, url, http.StatusSeeOther)
}
