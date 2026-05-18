package api

import (
	"net/http"

	"github.com/clicktion/service/internal/db"
)

// MARK: - Workflows landing page
//
// Two sections side-by-side: Open Todos (FIFO inbox) and Recent active
// notebooks (last 7 days, updated DESC). See docs/website-feature-review.md
// decision 10 for the design rationale.

type workflowsPage struct {
	Todos        []db.NotebookSummary
	Recent       []db.NotebookSummary
	RecentDays   int
}

func (h *handler) serveWorkflows(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/workflows" {
		http.NotFound(w, r)
		return
	}

	todos, _, err := h.db.ListNotebooks(db.NotebookFilter{
		OpenTodosOnly: true,
		OrderBy:       "todo_oldest", // oldest first — FIFO inbox
		Limit:         100,
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	recent, _, err := h.db.ListNotebooks(db.NotebookFilter{
		RecentDays: 7,
		Limit:      24,
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	renderTemplate(w, workflowsTmpl, "workflows.html", workflowsPage{
		Todos:      todos,
		Recent:     recent,
		RecentDays: 7,
	})
}
