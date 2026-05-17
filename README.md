# Clicktion

A native macOS menu bar app that captures screenshots, runs OCR, and sends them to an LLM for analysis using a skill-based workflow. Every capture is archived locally and accessible through a web UI.

---

## Requirements

| Tool | Version |
|------|---------|
| macOS | 14 (Sonoma) or later |
| Swift | 6.1+ (command line tools) |
| Go | 1.22+ |
| CGO | enabled (for SQLite) |

---

## Quick start

```bash
# 1. Clone
git clone <repo> Clicktion && cd Clicktion

# 2. Build and install default skills
make dev
```

`make dev` builds both binaries, assembles and signs the app bundle, installs the Go service and default skills into `~/Library/Application Support/Clicktion/`, and launches the app.

On first launch, a setup wizard walks you through:
1. Granting **screen recording** access (required)
2. Triggering the **local network** permission prompt
3. Adding your first **LLM model**
4. Running a **connection test**

---

## Capture dialog

When you capture a screenshot, a dialog appears before the capture is sent to the LLM:

| Area | Description |
|------|-------------|
| **Annotation toolbar** | Draw (freehand), add a text note, or select a region to crop |
| **Thumbnail** | Preview of the screenshot (or cropped region). Copy-to-clipboard button sits in the sidebar to the right |
| **OCR text** | Extracted text, selectable. Copy-to-clipboard button in the top-right corner |
| **Bottom bar** | Choose a skill (✦), then Cancel or **Action →** to send |
| **Advanced** | Collapsible section with profile picker (Thinking / Direct), privacy toggle (local-only vs. remote LLM), and image mode (Image + text / Text only) |

---

## Adding an LLM model

Clicktion works with any OpenAI-compatible endpoint. Open **Manage Models…** from the menu bar icon to add models via the web admin UI.

| Provider | Base URL | API key |
|----------|----------|---------|
| Ollama (local) | `http://localhost:11434/v1` | *(empty)* |
| LM Studio (local) | `http://localhost:1234/v1` | *(empty)* |
| Ollama on LAN | `http://192.168.x.x:11434/v1` | *(empty)* |
| OpenAI | `https://api.openai.com/v1` | `sk-…` |
| OpenRouter | `https://openrouter.ai/api/v1` | `sk-or-…` |

**Privacy note:** Endpoints at RFC1918 addresses or `localhost` are classified as **local** automatically. Private captures (the default) can only be processed by local models.

---

## Project structure

```
Clicktion/
├── Sources/Clicktion/          # Swift macOS app
│   ├── App/                    # Entry point, AppDelegate, AppState, ServiceManager
│   ├── Capture/                # ScreenCaptureKit, OCR, capture dialog
│   ├── LLM/                    # ServiceClient, ModelConfig
│   ├── Settings/               # SettingsView, SettingsWindow
│   ├── Skills/                 # Skill model, loader, editor views
│   └── UI/                     # Menu, chat window, setup wizard
├── clicktion-service/          # Go backend service
│   ├── cmd/server/             # main.go
│   ├── internal/
│   │   ├── api/                # HTTP handlers, router, SSE streaming
│   │   ├── db/                 # SQLite CRUD (captures, jobs, models, auth)
│   │   └── llm/                # OpenAI-compatible client, skill pre-selection
│   ├── web/
│   │   ├── templates/          # Go html/template pages (archive + admin)
│   │   └── static/             # CSS
│   └── vendor/                 # Vendored SQLite (CGo, mattn/go-sqlite3)
├── skills/                     # Default skill definitions (.md + .json pairs)
├── Clicktion.app/              # App bundle (binary excluded from git)
│   └── Contents/Info.plist
├── Clicktion.entitlements      # Screen capture + network entitlements
├── Package.swift               # Swift package definition
└── Makefile                    # Build targets
```

---

## Development workflow

```bash
make dev          # full rebuild + reinstall + relaunch (use after any change)
make go-build     # rebuild Go service only
make swift-build  # rebuild Swift app only (debug)
make swift-release # rebuild Swift app (release, used by make dev)
make install-skills # reinstall default skills from skills/
```

After `make dev`, the app relaunches automatically. No need to manually copy binaries.

---

## Web interfaces

With the app running, open these in any browser:

| URL | Description |
|-----|-------------|
| `http://localhost:8080/archive` | Browse all captures, search OCR text, view chat threads |
| `http://localhost:8080/admin` | Dashboard — LLM usage, model stats |
| `http://localhost:8080/admin/models` | Add / edit / test / delete LLM models |
| `http://localhost:8080/admin/keys` | Manage API keys |
| `http://localhost:8080/admin/storage` | Storage stats and bulk cleanup |

---

## Settings

Open **Settings…** from the menu bar icon (above Quit) to configure app-wide defaults. Settings are split across three tabs.

### General tab

| Setting | Description |
|---------|-------------|
| **Default model** | The model used for all captures. Fetched from the Go service; one model can be default at a time. |
| **Response language** | The language the LLM will always reply in. Defaults to the system locale. Appended to every skill prompt as `- You need to reply in <language>.` |

The full list of ~180 ISO languages is available with a live search field. The selection persists across launches.

### Privacy tab

| Mode | Description |
|------|-------------|
| **Private only — local LLMs** | Every capture stays on your network. Only models at `localhost` or RFC1918 addresses are used. The per-capture privacy toggle is hidden. |
| **Trust my LLM provider** | Captures can be sent to any configured model. A privacy toggle appears on each capture dialog so you can decide per capture. |

### Profiles tab

Two master profiles control LLM behaviour. The profile is selected per capture in the Advanced section of the capture dialog.

| Profile | Default behaviour |
|---------|------------------|
| **Thinking** | Reasoning enabled, prompts the model to think before answering. Best for complex analysis. Temperature: model default, max tokens: model default. |
| **Direct** | No reasoning steps shown. Concise answers, low temperature (0.3), 2048 token limit. |

Each profile exposes: master system prompt (prepended before the skill prompt), temperature slider (0–2, or model default), max tokens picker, and a thinking toggle (Thinking profile only). Changes persist across launches. A **Reset to defaults** button restores factory values.

---

## Skills

Skills define how the LLM responds to a capture. Each skill is two files in `~/Library/Application Support/Clicktion/skills/`:

**`skill-name.md`** — name, icon, trigger keywords, and the system prompt:
```markdown
---
name: Explain Error
icon: exclamationmark.triangle
triggers: error, exception, crash, stack trace
---

You are analyzing a screenshot containing an error message...
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

Edit skills from the menu bar: **Edit Skills…** opens a split-view native editor. Enabling `skip_confirmation` requires Touch ID or password authentication.

Default skills shipped: Explain Error, Generate Email Reply, Todo, Summarize, Write Documentation, Run CLI Command, Translate, Form Fill Assistant, Code Review, Extract & Structure Data.

---

## Go service API

The Mac app communicates with the Go service over HTTP. All `/api/` routes require `Authorization: Bearer <key>`.

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/bootstrap` | Create first API key (no auth; locked after first use) |
| `GET` | `/health` | Liveness check |
| `POST` | `/api/captures` | Submit a capture (image + OCR + skills), returns suggested skill |
| `POST` | `/api/jobs` | Start LLM execution for a capture with a chosen skill |
| `GET` | `/api/jobs/{id}/stream` | SSE stream of LLM tokens |
| `POST` | `/api/jobs/{id}/messages` | Send a follow-up message, re-triggers streaming |
| `GET` | `/api/models` | List configured models |
| `POST` | `/api/models` | Add a model |
| `PUT` | `/api/models/{id}` | Update a model |
| `DELETE` | `/api/models/{id}` | Delete a model |
| `POST` | `/api/models/{id}/test` | Test a model with a live request |
| `POST` | `/api/models/{id}/setdefault` | Mark a model as default (clears all others) |
| `GET` | `/api/auth/keys` | List API keys |
| `POST` | `/api/auth/keys` | Create an API key |
| `DELETE` | `/api/auth/keys/{id}` | Delete an API key |

---

## Data storage

Everything lives in `~/Library/Application Support/Clicktion/`:

```
Clicktion/
├── clicktion-service   # Go binary (installed by make dev)
├── clicktion.db        # SQLite database
├── captures/           # Screenshot PNG files
└── skills/             # Skill .md and .json files
```

The SQLite database holds captures, chat threads, LLM call logs, model configs, and API keys. Screenshot files are stored on disk and referenced by path in the database.

---

## Future: remote deployment

The Go service is designed to run on a remote server with no code changes. To migrate:

1. Deploy `clicktion-service` on a remote host
2. Update the service URL in the Mac app (menu → service settings)
3. The API key authentication is already in place
4. Private capture enforcement remains: the service refuses to send private captures to remote LLM endpoints

---

## Privacy

- **Default: private.** Every capture is marked private unless the user explicitly toggles it to public in the capture dialog.
- **Local-only enforcement.** Private captures are blocked from being sent to any non-local LLM endpoint at the service layer — not just the UI.
- **No telemetry.** Nothing leaves your machine unless you configure a remote LLM model and explicitly mark a capture as public.
