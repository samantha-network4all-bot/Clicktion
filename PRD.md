# Clicktion — Product Requirements Document

## Overview

Clicktion is a native macOS menu bar application that lets users capture screenshots or screen regions, analyze them with an LLM, and act on the result through a skill-based workflow. Every capture is archived in a local database service that is designed to move to a remote server in the future.

---

## Platform & Requirements

- **OS:** macOS 14 (Sonoma) or later
- **Language:** Swift + SwiftUI (Mac app), Go (backend service)
- **Distribution:** Direct download (no App Store initially — requires screen recording permission)

---

## Architecture

### Monorepo Structure

```
Clicktion/
  Clicktion.xcodeproj/     # Swift macOS app
  clicktion-service/       # Go service
    vendor/                # Vendored SQLite (mattn/go-sqlite3, CGo)
  skills/                  # Default .md + .json skill files
  docs/
```

### Mac App (Swift + SwiftUI)
- Menu bar extra (NSStatusItem)
- Capture UI via `SCContentSharingPicker` + `ScreenCaptureKit`
- OCR via macOS Vision framework (`VNRecognizeTextRequest`)
- Thin client — all persistence and LLM calls go through the Go service
- API key stored in macOS Keychain

### Go Service
- Stdlib only: `net/http`, `html/template`, `encoding/json`
- One vendored CGo dependency: SQLite via `mattn/go-sqlite3`
- REST API + Server-Sent Events (SSE) for LLM streaming
- Serves archive web UI and admin web UI
- Bundled inside `.app`, started/stopped automatically by the Mac app
- Default local address: `http://localhost:8080`

---

## Privacy Model

- **All screenshots are private by default.** Private screenshots may only be processed by a local LLM (RFC1918 or localhost endpoint).
- Users must explicitly mark a screenshot as **public** to allow processing by a remote LLM.
- If the user has only configured a remote model, they may override the private restriction with an explicit confirmation warning.
- Local vs remote classification is automatic based on the endpoint URL:
  - RFC1918 ranges (`10.x`, `172.16–31.x`, `192.168.x`) and `localhost` → **local**
  - All other URLs → **remote**
  - Users can manually override the classification.

---

## LLM Integration

- All LLM endpoints use the **OpenAI-compatible API** (`/v1/chat/completions`)
- Supported providers: Ollama, LM Studio, llama.cpp server, OpenRouter, OpenAI, any OpenAI-compatible endpoint
- Model configuration lives in the **Go service** (not the Mac app)
- The Mac app configures models via `POST /config/models` during setup and from the menu

### Model Configuration Fields
- Base URL (e.g. `http://192.168.1.10:11434/v1`)
- API key (empty for local)
- Model name (e.g. `llama3.2-vision`, `gpt-4o`)
- Local/remote classification (auto-detected, manually overridable)

### Fallback Chain
- Multiple models can be configured with a priority order
- If the primary model fails, the next in the chain is used automatically
- The user is **notified** when a fallback model is used

### Performance Metrics (Status Bar)
- Latency (time to first token, total response time)
- Token usage (prompt + completion)
- Success rate
- Request count
- Avg tokens/second
- Health indicator per model (green / yellow / red)

---

## Startup Wizard

Runs on first launch and is re-accessible from the menu ("Setup Wizard…"):

1. Start the bundled Go service
2. Collect service URL (default: `localhost:8080`)
3. Add first LLM model (URL, API key, model name)
4. Auto-classify as local or remote
5. Send test request (small image, verify vision capability)
6. Show pass/fail with model response
7. Option to add additional models and set default

---

## Capture Flow

1. User clicks Clicktion icon in menu bar
2. User selects a window or region via `SCContentSharingPicker`
3. Screenshot is taken; Vision framework runs OCR immediately
4. **Capture dialog** appears:
   - Thumbnail of the screenshot
   - Selectable OCR text (selecting text copies to clipboard)
   - Source app name + window title (`SCWindow.owningApplication.applicationName` + `SCWindow.title`)
   - Privacy toggle (default: private/locked)
   - LLM pre-processes capture and **suggests a skill**
5. User reviews suggested skill, can change it, then hits **Send / Continue**
6. **Chat dialog** opens — full back-and-forth conversation thread
   - Screenshot + OCR text stay in LLM context for the entire thread
   - LLM output streams in token by token (SSE)
   - Skill may ask follow-up questions
7. Capture, OCR, skill used, chat history, and LLM logs are archived in SQLite

---

## Skills System

### File Format

Each skill consists of two files with matching names:

**`skill-name.md`** — system prompt (edited with rich text editor in-app):
```markdown
---
name: Explain Error
icon: exclamationmark.triangle
triggers: error, exception, crash, stack trace, bug
---

You are analyzing a screenshot containing an error message or stack trace...
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

### Storage Location
`~/Library/Application Support/Clicktion/skills/`

### Skill Editor
- Accessible from the menu bar ("Edit Skills…")
- Rich text editor for the `.md` file
- Structured form (toggles, dropdowns, list editor) for the `.json` security config
- Users never see raw JSON
- Skills with `skip_confirmation: true` require Touch ID or password to enable

### Security Parameters
| Parameter | Type | Description |
|-----------|------|-------------|
| `allow_cli` | bool | Can execute shell commands |
| `allow_file_write` | bool | Can write/modify files on disk |
| `allow_network` | bool | Can make outbound network calls |
| `skip_confirmation` | bool | Dangerous actions skip confirmation prompt |
| `danger_level` | string | `none` / `low` / `medium` / `high` — shown as badge in editor |
| `blocklist` | array | Forbidden command patterns for CLI skills |

### CLI Skill Execution
- LLM suggests a command in the chat thread
- Distinct "Run this command" button — never auto-executes
- Command shown in read-only code block before running
- Destructive patterns (`rm`, `sudo`, `dd`, etc.) show additional warning banner
- Runs in user's login shell (`$SHELL`) with full environment
- Output streams back into the chat thread

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

- Flags a screenshot for later review
- LLM asks for a short note describing why it's flagged
- **Menu bar icon shows a dot indicator** when open todos exist (Apple-style simplicity)
- Menu bar dropdown lists most recent todos (up to 5), each clickable to reopen chat
- "Mark as done" available inside the chat thread and in the archive web UI

---

## Database & Archive

### SQLite Schema (key tables)
- `captures` — id, timestamp, image path, ocr_text, app_name, window_title, privacy, skill_used, is_todo, todo_note
- `chat_messages` — id, capture_id, role, content, timestamp
- `llm_logs` — id, capture_id, model_used, prompt_tokens, completion_tokens, latency_ms, timestamp
- `models` — id, name, base_url, api_key, is_local, is_default, fallback_order
- `api_keys` — id, key_hash, label, created_at

### Archive Web UI
- Grid/list view of thumbnails, sortable by date/skill/tag
- Full-text search by OCR content
- Filter by skill, private/public, todo-flagged
- Click thumbnail → reopens chat thread
- Bulk delete / export
- Storage size indicator + auto-cleanup options

### Admin Web UI
- Model management (add, edit, delete, set fallback order)
- API key management
- Storage statistics
- Service health / logs

---

## Authentication

- Mac app generates a random API key on first launch
- Stored in macOS Keychain
- Sent as `Authorization: Bearer <key>` on every request to the Go service
- Go service supports multiple API keys (for future multi-client support)
- Auth is in place from day one to support future remote deployment

---

## Future / Remote Deployment

The Go service is designed to be moved to a remote server with minimal changes:
- Mac app only needs to know the service base URL (configurable in menu)
- Auth already in place
- LLM calls proxied through the service (not made directly by the Mac app)
- Private screenshot enforcement: the service checks privacy flag before routing to any remote LLM
- Archive and admin web UIs become remotely accessible

---

## UX Principles

- **Apple simplicity** — minimal chrome, familiar patterns, no unnecessary UI
- **Privacy first** — private by default, local LLM required for private captures
- **Non-intrusive** — lives in the menu bar, out of the way until needed
- **Transparent** — always shows which model is being used, notifies on fallback
