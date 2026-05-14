# Clicktion — Product Requirements Document

## Overview

Clicktion is a native macOS menu bar application that lets users capture screenshots or screen regions, analyze them with an LLM, and act on the result through a skill-based workflow. Every capture is archived in a local database service designed to move to a remote server in the future.

---

## Platform & Requirements

- **OS:** macOS 14 (Sonoma) or later
- **Language:** Swift + SwiftUI (Mac app), Go (backend service)
- **Distribution:** Direct download (no App Store — requires screen recording permission)

---

## Architecture

### Repository Structure

```
Clicktion/
  Package.swift            # Swift Package Manager definition
  Clicktion.app/           # App bundle (binary excluded from git)
    Contents/Info.plist
  Clicktion.entitlements   # Screen capture + network entitlements
  Makefile
  Sources/Clicktion/       # Swift source
    App/                   # Entry point, AppDelegate, AppState, ServiceManager, Keychain
    Capture/               # CaptureManager, OCRProcessor, capture dialog
    LLM/                   # ServiceClient, ModelConfig
    Skills/                # Skill model, SkillLoader, skill editor views
    UI/                    # Menu, chat window, setup wizard, message views
  clicktion-service/       # Go backend service
    cmd/server/            # main.go
    internal/api/          # HTTP handlers, router, SSE streaming, job runner
    internal/db/           # SQLite CRUD (captures, jobs, models, auth, archive, admin)
    internal/llm/          # OpenAI-compatible client, skill pre-selection
    web/templates/         # Go html/template pages (archive + admin)
    web/static/            # CSS stylesheet
    vendor/                # Vendored SQLite (mattn/go-sqlite3, CGo)
  skills/                  # Default skill definitions (.md + .json pairs)
```

### Mac App (Swift + SwiftUI)

- Menu bar extra (`NSStatusItem`) — no Dock icon (`LSUIElement = true`)
- Capture UI via `SCContentSharingPicker` + `ScreenCaptureKit`
- OCR via macOS Vision framework (`VNRecognizeTextRequest`) — runs on-device
- Thin client — all persistence and LLM calls go through the Go service
- API key stored in macOS Keychain
- Service lifecycle managed by `ServiceManager` (starts/stops the Go binary)

### Go Service

- Standard library only: `net/http`, `html/template`, `encoding/json`
- One vendored CGo dependency: SQLite via `mattn/go-sqlite3`
- REST API + Server-Sent Events (SSE) for LLM token streaming
- Serves archive web UI and admin web UI
- Bundled inside `.app`, started automatically on launch
- Binds to `127.0.0.1:8080` by default

---

## Privacy Model

- **All screenshots are private by default.** Private screenshots may only be processed by a local LLM (RFC1918 or localhost endpoint).
- Users must explicitly toggle a screenshot to **public** in the capture dialog to allow remote LLM processing.
- If only a remote model is configured, the user sees an explicit override warning.
- Local vs remote classification is automatic based on the endpoint URL:
  - RFC1918 ranges (`10.x`, `172.16–31.x`, `192.168.x`) and `localhost` / `127.0.0.1` → **local**
  - All other URLs → **remote**
  - Users can manually override the auto-classification per model.
- Enforcement is at the **service layer** — the Go service checks the privacy flag before selecting a model, not just in the UI.

---

## LLM Integration

- All LLM endpoints use the **OpenAI-compatible API** (`/v1/chat/completions`)
- Supported providers: Ollama, LM Studio, llama.cpp, OpenRouter, OpenAI, any OpenAI-compatible endpoint
- Model configuration lives in the **Go service** (`/api/models`)
- Models support vision input (base64-encoded PNG in message content)

### Model Configuration Fields

| Field | Description |
|-------|-------------|
| `name` | Display name |
| `base_url` | Endpoint URL (e.g. `http://localhost:11434/v1`) |
| `api_key` | Bearer token (empty for local models) |
| `model_name` | Model identifier (e.g. `llama3.2-vision`, `gpt-4o`) |
| `is_local` | Auto-detected from URL; can be overridden |
| `is_default` | Whether this is the preferred model |
| `fallback_order` | Lower = tried first in fallback chain |

### Fallback Chain

- Multiple models configured with a `fallback_order`
- If the primary model fails, the service automatically tries the next in the chain
- The Mac app is **notified** when a fallback model is used (status bar indicator)
- Private captures only fall back within local models

### LLM Logging

Every LLM call is logged in `llm_logs` with: model name, prompt tokens, completion tokens, latency (ms), and any error. Visible in the admin dashboard.

---

## Startup Sequence

### First Launch Wizard (5 steps)

1. **Welcome** — introduction screen
2. **Permissions** — checks screen recording access (required; live status polling); triggers local network permission prompt for LAN model access
3. **Add Model** — endpoint URL, API key, model name; auto-classifies local/remote with live indicator
4. **Test Model** — sends a live request to verify the model works
5. **Done** — wizard complete

### Service Bootstrap

On every launch (wizard or not), `ServiceManager` runs:

1. Start the bundled Go service binary
2. Poll `GET /health` until the service responds (500ms interval, 15s max)
3. Call `POST /bootstrap` if no API key exists in Keychain — creates the first key and saves it; the endpoint returns 403 after any key exists
4. Fetch `GET /api/models` and populate `AppState.activeModel`
5. Set `AppState.isServiceReady = true`

---

## Capture Flow

1. User clicks Clicktion icon in menu bar → **Capture Screen** button
2. User selects a window or region via `SCContentSharingPicker`
3. Screenshot taken; Vision framework runs OCR immediately (on-device)
4. **Capture dialog** appears:
   - Full-width screenshot thumbnail
   - Selectable OCR text — selecting copies to clipboard
   - Source app name + window title (from `SCWindow`)
   - Privacy toggle (default: private / locked)
   - LLM pre-processes the capture and suggests a skill (non-streaming call)
5. User reviews the suggested skill, optionally changes it, hits **Send**
6. Service creates a job (`POST /api/jobs`) with the confirmed skill and system prompt; begins LLM execution
7. **Chat window** opens and immediately streams the response via `GET /api/jobs/{id}/stream` (SSE)
8. User can send follow-up messages — each triggers a new LLM response in the same thread
9. Capture, OCR text, chat history, and LLM logs are persisted in SQLite

---

## Skills System

### File Format

Each skill is two files with matching names in `~/Library/Application Support/Clicktion/skills/`:

**`skill-name.md`** — name, icon, trigger keywords, system prompt:

```markdown
---
name: Explain Error
icon: exclamationmark.triangle
triggers: error, exception, crash, stack trace, bug
---

You are analyzing a screenshot containing an error message or stack trace.
(system prompt continues)
```

**`skill-name.json`** — security configuration:

```json
{
  "allow_cli": false,
  "allow_file_write": false,
  "allow_network": false,
  "skip_confirmation": false,
  "danger_level": "none",
  "blocklist": []
}
```

### Skill Editor (native macOS window)

Opened from menu bar → **Edit Skills…**

- **Left sidebar:** list of all skills with icon, name, trigger preview, danger badge
- **Detail pane:**
  - Identity: Name, SF Symbol icon (live preview), comma-separated triggers (shown as chips)
  - System prompt: monospaced `TextEditor` with focus ring, character count
  - Security: danger level segmented picker, permission toggles, editable blocklist
- Enabling `skip_confirmation` requires Touch ID or password (`LAContext`)
- Save (Cmd+S), Discard, Delete with `confirmationDialog`
- Unsaved-changes guard when switching skills

### Skill Pre-selection

When a capture is submitted, the Go service makes a fast non-streaming LLM call with:
- All available skill names and trigger keywords (sent from the Mac app in the capture payload)
- Capture context: app name, window title, OCR text sample

The LLM responds with the most appropriate skill name. The Mac app pre-selects it in the capture dialog; the user can override.

### Security Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `allow_cli` | bool | Can execute shell commands |
| `allow_file_write` | bool | Can write/modify files on disk |
| `allow_network` | bool | Can make outbound network calls beyond the LLM |
| `skip_confirmation` | bool | Dangerous actions run without a confirmation prompt |
| `danger_level` | string | `none` / `low` / `medium` / `high` — badge in editor |
| `blocklist` | array | Command patterns blocked from execution |

### CLI Skill Execution

- LLM suggests a command rendered in a code block in the chat window
- **Run** button appears only when `allow_cli: true` on the skill
- Non-destructive commands: show a confirmation sheet before running
- Destructive commands (matches `blocklist`): show a red destructive alert
- `skip_confirmation: true`: runs without prompting (requires Touch ID to enable)
- Runs in user's login shell (`$SHELL`) with full environment
- stdout + stderr stream back into the chat thread as a code block

---

## Default Skills (10)

| Skill | Trigger keywords | CLI | Danger |
|-------|-----------------|-----|--------|
| Explain Error | error, exception, crash, stack trace | No | None |
| Generate Email Reply | email, reply, compose, inbox | No | None |
| Todo | todo, later, flag, remind | No | None |
| Summarize | summarize, tldr, condense, article | No | None |
| Write Documentation | docs, document, comment, readme | No | None |
| Run CLI Command | command, terminal, cli, shell, run | Yes | High |
| Translate | translate, language | No | None |
| Form Fill Assistant | form, field, fill | No | None |
| Code Review | code, review, bug, refactor | No | None |
| Extract & Structure Data | table, csv, json, extract, data | No | None |

---

## Todo Skill

- Flags a screenshot for later review; LLM asks for a short note
- Menu bar icon shows a **dot indicator** when open todos exist
- Menu bar dropdown lists recent open todos
- "Mark as done" available inside the chat thread and in the archive web UI

---

## Database Schema

SQLite at `~/Library/Application Support/Clicktion/clicktion.db`.

```sql
captures      -- id, image_path, ocr_text, app_name, window_title,
              --   is_private, skill_used, is_todo, todo_note, todo_done, created_at
chat_messages -- id, capture_id, role (user|assistant|system), content, created_at
jobs          -- id, capture_id, model_id, skill_name, skill_prompt,
              --   status (pending|running|done|failed), created_at, finished_at
llm_logs      -- id, job_id, model_name, prompt_tokens, completion_tokens,
              --   latency_ms, error, created_at
models        -- id, name, base_url, api_key, model_name, is_local,
              --   is_local_override, is_default, fallback_order, created_at
api_keys      -- id, key_hash, label, created_at
```

Screenshot PNG files are stored in `~/Library/Application Support/Clicktion/captures/` and referenced by path.

---

## Archive Web UI (`/archive`)

- Responsive thumbnail grid (`auto-fill, minmax(220px, 1fr)`)
- Full-text search across OCR text, app name, window title
- Filter tabs: All / Todos / Public
- Skill filter dropdown (populated from distinct values in DB)
- Each card: thumbnail, app name, skill badge, privacy badge, time ago, Open/Delete actions
- Click → capture detail page: metadata, collapsible OCR text, full chat thread
- Pagination (48 per page)
- Delete with `window.confirm()` guard; redirects after delete

---

## Admin Web UI (`/admin`)

### Dashboard (`/admin`)
- Stat cards: total captures, open todos, models configured, disk usage
- LLM usage aggregated by model (call count, avg latency, token totals)
- Recent LLM call log (last 10)

### Model Management (`/admin/models`)
- Table: name, endpoint URL, model name, local/remote badge, fallback order, default flag
- Inline test button (live request, result shown as flash on redirect)
- Edit form: all fields, local override dropdown, fallback order
- Set default, delete (with `confirm()`)

### API Keys (`/admin/keys`)
- Table of keys (label + created time; hash not shown)
- Create form: generates 32-byte random key, shows plaintext **once** on a dedicated page with clipboard button
- Delete with confirm

### Storage (`/admin/storage`)
- Stat cards + LLM usage by model
- Cleanup form: delete captures older than N days (deletes DB rows + image files)

---

## Authentication

- On first launch, `ServiceManager` calls `POST /bootstrap` to create the initial API key
- Key stored in macOS Keychain; sent as `Authorization: Bearer <key>` on every request
- `POST /bootstrap` returns 403 once any key exists — cannot be replayed
- Admin web UI is served without auth (local-only bind to `127.0.0.1`)
- Go service supports multiple API keys for future multi-client access

---

## Future / Remote Deployment

The Go service is designed to migrate to a remote server with no code changes:

- Mac app only needs the service base URL updated
- Auth (Bearer tokens) is already in place
- LLM calls proxied through the service — the Mac app never calls LLM endpoints directly
- Private capture enforcement is server-side: the service checks `is_private` before selecting a model
- Archive and admin web UIs become remotely accessible over HTTPS

---

## UX Principles

- **Apple simplicity** — minimal chrome, familiar macOS patterns, no unnecessary UI
- **Privacy first** — private by default, local LLM enforced at the service layer
- **Non-intrusive** — lives in the menu bar, out of the way until triggered
- **Transparent** — status indicator shows active model, notifies on fallback
