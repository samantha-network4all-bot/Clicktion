# Clicktion website feature review

## Context

The user wants to review the features of the Clicktion web interface (the HTML pages served by the Go service on `localhost:8080`). This is **not** an implementation task yet — it's a design conversation to decide what to keep, change, remove, and add. Outcome: a concrete list of decisions that can become follow-up implementation tickets.

## Current state (captured from exploration)

The Go service serves 9 web-facing routes today, grouped in two areas:

**Archive (end-user)**
- `GET /archive` — capture gallery, 48-per-page, full-text search across OCR/app/window, filters (All / Todos / Public), skill dropdown, pagination preserving filters
- `GET /archive/captures/{id}` — capture detail: full screenshot, OCR text, chat thread (read-only), delete button

**Admin (operator)**
- `GET /admin` — dashboard: storage stats, model count, capture/todo counts, LLM usage table, recent LLM call logs
- `GET /admin/models` + `/new` + `/{id}/edit` — model CRUD with test/setdefault, JS-driven model name fetcher
- `GET /admin/keys` + `POST` + `/key_created` — API key management with one-time plaintext reveal
- `GET /admin/storage` — storage stats + cleanup-by-age form

**Important traits:**
- No authentication on `/archive` or `/admin` — only `/api/*` requires Bearer key
- All state via URL query params (no session)
- Built-in JS for: model probe (proxied via `/admin/models/probe`), filter submit, copy-to-clipboard, delete confirmations
- Form labels lack `for` attributes; no ARIA roles

## Decisions (filled during the grill)

| # | Decision | Choice | Reasoning |
|---|----------|--------|-----------|
| 1 | Target audience / deployment scope | **A now, architecturally ready for C** | Service is normally local backend per workstation. User has multiple workstations (Mac + possibly Windows) and wants long-term ability to sync todos / chat history across them — eventual route is a shared service (Docker-deployable). Decisions today must not block that future move (no Docker dep yet, but design choices should be portable). |
| 2 | Auth on `/archive` and `/admin` | **None — keep `127.0.0.1` binding** | Single-user single-machine. Future multi-user/multi-desktop solved by adding a *second* database (sync + isolation) on a separate service tier, not by retrofitting auth onto the local DB. Clean separation of concerns. No code change needed: `main.go` already binds `127.0.0.1:8080`. |
| 2b | Sync topology (future) | **Hub-and-spoke via central Docker, never peer-to-peer** | Laptops will not talk directly to each other on the LAN. Each workstation runs a fully local service; sync (if/when implemented) happens via push/pull against a central Docker-hosted service. Confirms decision 2: no LAN-listener mode is needed, no service discovery, no peer auth. |
| 3 | Approach | **Brainstorm features first, then design page layout** | User wants to enumerate desired features before deciding where they live on the site. |
| 4 | "Todo" becomes a first-class capture action (not a skill) | **Yes** | In the capture dialog, alongside the skill list, the user can pick "Todo" instead of a skill. Picking Todo stores the capture in the DB (with `is_todo=1`, `skill_used=NULL`) **without** running any LLM, then dismisses the dialog. Use case: snapshot a task you see in Teams/Slack/etc. and come back to it later. Picking a *skill* continues to do what it does today (run LLM immediately, open chat). |
| 5 | Top-level information architecture | **Three buckets: Workflows, Archived data, Administrative** | All features and pages slot into one of these three areas. Workflows = items you take action on (todos, in-progress chats). Archived data = browse / search the historical record. Administrative = models, storage, etc. |
| 6 | Todo continuation location | **In the browser** | When user clicks a skill on a todo from the web, the LLM runs and the response streams **in the web page**, not in the Mac app. Makes the web a self-sufficient workspace and lines up with the future Docker-hosted-service scenario where the browser is the only client. Requires: SSE streaming in browser, web-side chat UI, skill picker on todo detail. |
| 7 | Web chat interactivity | **Fully interactive — Jupyter-notebook style** | Capture detail page becomes a complete chat surface, modeled after a Jupyter notebook: cells you can re-run, edit, iterate on, rather than a linear chat log. |
| 8 | Notebook semantics | **All four: cells + editable inputs + multi-capture + markdown cells** | A notebook is a document of ordered cells. Cell types: capture (image+OCR+LLM response), follow-up turn, markdown (free text). Every cell is re-runnable; inputs (OCR, prompt) are editable; one notebook can contain multiple captures (chain outputs); markdown cells let you annotate. Big architectural shift — requires new data model. |
| 9 | Notebook creation | **Every capture auto-creates its own notebook** | New capture → fresh 1-cell notebook. From the browser the user can append cells (markdown, more captures, follow-up turns). Mac app capture flow unchanged. Existing chat threads migrate to cells in the auto-created notebook. Todo = a notebook with just the capture cell and no response cell yet. |
| 10 | Workflows bucket population | **Todos + Recent active** | Decided not to introduce a separate "Draft" concept — Drafts and Todos collapse into one "snapshot for later" idea (`is_todo=1`). Workflows bucket shows: open Todos + Recent active notebooks (activity in last N days). |
| 11 | Administrative bucket | **Models, Storage, Dashboard** | API keys management page is dropped (Mac app bootstraps its own key; single-user setup has no need for managing other clients). Keys infrastructure stays in the API for future multi-client scenarios but no UI is exposed. |
| 12 | Archived data extras | **Date-range filter + sort options** | On top of existing OCR/app/window search + Todo/Public/Skill filters. Sort by: created (default), last activity, message count, model used. No user tagging in MVP, no related-notebook suggestions in MVP. |
| 13 | Todo "done" mechanics | **Explicit Done button** | The notebook detail page shows a "Mark done" button while `is_todo=1, todo_done=0`. Running a skill on the todo does **not** auto-complete it — todos stay open until the user explicitly ticks them off. No auto-archive-after-N-days. |

## Feature inventory per bucket

### 🔄 Workflows
Items the user is actively working on.
- **Todos list** — notebooks with `is_todo=1, todo_done=0`, sorted oldest first (FIFO inbox feel).
- **Recent active list** — notebooks with any activity (capture, edit, follow-up, re-run) in the last N days. Configurable window.
- **Mark-done action** on notebook detail page (only visible while is_todo=1).

### 📚 Archived data
The historical record of everything the user has captured.
- Existing: OCR/app/window full-text search, filters (All / Todo / Public), skill dropdown, pagination.
- **NEW**: date-range filter (from … to).
- **NEW**: sort dropdown — Created (default) / Last activity / Message count / Model used.
- Notebook detail page = Jupyter-style cells (see Data model).

### ⚙️ Administrative
Backend operations.
- Models (CRUD + test + setdefault + JS probe) — kept as-is.
- Storage (stats + manual cleanup by age) — kept as-is.
- Dashboard (LLM logs, token usage, latency, recent calls) — kept as-is.
- **DROP**: `/admin/keys` page. Routes stay in the API; UI gone.

## Capture dialog (Mac app) changes

Right-hand skill sidebar gains a **"Todo"** entry above (or below) the skill list:
- Picking a skill → existing behaviour (LLM runs, chat opens).
- Picking **Todo** → POST `/api/captures` with `is_todo=1`; do NOT call `/api/jobs`; dismiss the dialog. The user can come back via Workflows → Todos in the browser.

## Data model

New tables, additive to today's schema:

```
notebooks
  id            TEXT PRIMARY KEY
  title         TEXT                       (auto-derived from first capture's app/window)
  is_todo       INTEGER NOT NULL DEFAULT 0
  todo_done     INTEGER NOT NULL DEFAULT 0
  created_at    DATETIME
  updated_at    DATETIME                   (touched on every cell change)

notebook_cells
  id            TEXT PRIMARY KEY
  notebook_id   TEXT NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE
  position      INTEGER NOT NULL          (ordered; allow gaps for cheap reordering)
  kind          TEXT NOT NULL              ('capture' | 'response' | 'markdown')
  capture_id    TEXT                       (set for capture cells)
  content       TEXT                       (markdown body, or LLM response text)
  thinking      TEXT                       (reasoning_content if applicable)
  skill_name    TEXT                       (for response cells)
  model_used    TEXT
  created_at    DATETIME
```

Migration of existing data:
- For every existing `captures` row → create a `notebooks` row, inherit `is_todo`/`todo_done`.
- For each existing capture → create `notebook_cells` row of kind `capture` at position 0.
- For each `chat_messages` row in chronological order → append a cell (`response` for assistant, treat user messages as part of preceding cell's content or as new cells).
- Keep `captures` and `chat_messages` tables read-compatible during a transition period; new writes go through the notebook abstraction.

## Phased implementation (sketch — each phase ships independently)

**P1 — Foundation + Todo workflow** (≈ first usable slice)
1. Schema migration + notebook abstraction at the DB / API layer.
2. Capture-dialog Todo button (Mac).
3. Replace `/archive/captures/{id}` with notebook detail page: render cells (capture + response cells), keep read-only first.
4. Web nav restructure: 3 top-level buckets, remove `/admin/keys` link.
5. Workflows landing page with Todos list + Recent active list.
6. Mark-done button on todo notebooks.

**P2 — Interactive notebook**
1. Streaming-aware web chat: SSE in the browser, follow-up input, skill switcher, regenerate.
2. Re-run any cell with a different skill / profile / mode.
3. Edit OCR text on a capture cell → re-run.
4. Date-range filter + sort dropdown on Archived data.

**P3 — Full Jupyter parity** *(P3.1 + P3.2 shipped; P3.3 deferred)*
1. ✅ Markdown cells (add between any two cells).
2. ✅ Multi-capture notebooks — append a capture from the browser via file upload. *(“Add to existing notebook” from the Mac app is still TODO.)*
3. ⏸ Chain references (cell B's prompt interpolates cell A's output) — **deferred**. Multi-capture notebooks raise design questions about which capture a follow-up/regenerate should target, whether each capture cell deserves its own "Run skill" lane, and the syntax / preview UX for interpolations. A short grilling session before code.

## Files that may be affected (per phase)

- **Mac app**: `Sources/Clicktion/Capture/CaptureDialogView.swift`, `CaptureDialogViewModel.swift`, `LLM/ServiceClient.swift`.
- **Go service core**: `internal/db/db.go` (schema + migrations), new `internal/db/notebooks.go`, modify `internal/db/captures.go` and `internal/db/archive.go`.
- **API handlers**: new `internal/api/handler_notebooks.go`, modify `internal/api/handler_archive.go` and `handler_admin.go` (drop keys UI), router edits.
- **Web**: new `web/templates/notebook.html`, `workflows.html`; modify `archive.html`, `base.html` (3-bucket nav); remove `admin_keys.html` and `admin_key_created.html` from menu; new `web/static/notebook.js` for cell interactions and SSE.
- **Skills**: the existing "Todo" skill (`skills/todo.md`) is now redundant — remove or repurpose.

## Verification (per phase, end-to-end)

**P1 verification** — purely visible smoke tests, no automated suite:
- Take a fresh capture in the Mac app; click "Todo"; confirm dialog closes without opening chat.
- Open `http://localhost:8080/workflows`; the new todo appears in the Todos list.
- Open the notebook; see capture cell with image + OCR; no skill response yet; "Mark done" button visible.
- Click "Mark done"; notebook leaves Todos list, remains in Archive.
- Take a fresh capture and pick a skill: notebook auto-created, response cell rendered, todo not flagged.
- Browse `/archive`; no "Keys" entry in nav; no link to `/admin/keys`.

**P2 verification**: type a follow-up in the browser → response streams; edit OCR + re-run a cell → cell shows fresh response.

**P3 verification**: add a markdown cell between two cells → persists across reload; add a second capture cell via "Add capture" button → second cell streams correctly.

## Out-of-scope decisions deferred to a later plan

- Exact page-by-page layout / wireframes (this plan settles features and IA, not pixels).
- Sync layer + Docker hub-and-spoke deployment (decision 2b deferred to its own plan).
- User tagging, related-notebook suggestions, pinned notebooks, failed-job inbox (rejected in P1/P2 scope; reconsider after P3 if needed).
