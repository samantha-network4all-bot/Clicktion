package api

import (
	"context"
	"encoding/base64"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/clicktion/service/internal/db"
	"github.com/clicktion/service/internal/llm"
	"sync"
)

// jobStream delivers tokens immediately via a channel.
// Closed when the LLM finishes or errors out.
type jobStream struct {
	ch  chan string
	mu  sync.Mutex
	err error
}

func newJobStream() *jobStream {
	return &jobStream{ch: make(chan string, 4096)}
}

func (s *jobStream) push(token string) {
	select {
	case s.ch <- token:
	default:
		// Buffer full — drop token rather than blocking the LLM goroutine.
		// The SSE client will see gaps but won't deadlock.
	}
}

func (s *jobStream) finish(err error) {
	s.mu.Lock()
	s.err = err
	s.mu.Unlock()
	close(s.ch)
}

func (s *jobStream) streamErr() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.err
}

var activeStreams sync.Map // string(jobID) → *jobStream

// runJob registers the stream immediately (before the goroutine starts) to
// eliminate the race where the SSE client connects before Store is called.
// The stream stays in activeStreams for 2 minutes after the job finishes so
// a client that connects after the LLM is done (fast local models) can still
// read the buffered tokens from the channel rather than falling into the
// one-shot replay path.
func (h *handler) runJob(jobID string) {
	stream := newJobStream()
	activeStreams.Store(jobID, stream)

	go func() {
		// Do NOT defer activeStreams.Delete here — keep the stream alive so
		// late-connecting SSE clients can drain the buffered channel.
		// A separate goroutine cleans up after a TTL.
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()

		if err := h.executeJob(ctx, jobID, stream); err != nil {
			log.Printf("job %s failed: %v", jobID, err)
			stream.finish(err)
			h.db.UpdateJobStatus(jobID, "failed")
			// Still schedule cleanup
			go func() { time.Sleep(2 * time.Minute); activeStreams.Delete(jobID) }()
			return
		}

		stream.finish(nil)
		h.db.UpdateJobStatus(jobID, "done")
		// Schedule cleanup so the map doesn't grow forever.
		go func() { time.Sleep(2 * time.Minute); activeStreams.Delete(jobID) }()
	}()
}

func (h *handler) executeJob(ctx context.Context, jobID string, stream *jobStream) error {
	job, err := h.db.GetJob(jobID)
	if err != nil {
		return err
	}
	capture, err := h.db.GetCapture(job.CaptureID)
	if err != nil {
		return err
	}

	history, err := h.db.ListChatMessages(job.CaptureID)
	if err != nil {
		return err
	}

	models, err := h.db.FallbackChain(capture.IsPrivate)
	if err != nil || len(models) == 0 {
		return fmt.Errorf("no suitable model configured")
	}

	opts := llm.StreamOptions{
		Temperature: job.Temperature,
		MaxTokens:   job.MaxTokens,
	}

	var lastErr error
	for i, model := range models {
		client := llm.NewClient(model.BaseURL, model.APIKey, model.ModelName)
		result, err := h.streamWithModel(ctx, client, job, capture, history, stream, i > 0, opts)
		if err == nil {
			h.db.AddLLMLog(db.LLMLog{
				JobID:            jobID,
				ModelName:        model.ModelName,
				PromptTokens:     result.PromptTokens,
				CompletionTokens: result.CompletionTokens,
				LatencyMs:        result.LatencyMs,
			})
			return nil
		}
		lastErr = err
		log.Printf("model %s failed for job %s: %v — trying fallback", model.Name, jobID, err)
		stream.push("[FALLBACK:" + model.Name + "]")
	}
	return lastErr
}

func (h *handler) streamWithModel(
	ctx context.Context,
	client *llm.Client,
	job *db.Job,
	capture *db.Capture,
	history []db.ChatMessage,
	stream *jobStream,
	isFallback bool,
	opts llm.StreamOptions,
) (llm.StreamResult, error) {
	messages := buildMessages(job, capture, history, job.SendImage)

	var fullResponse string
	var receivedAnyToken bool
	result, err := client.Stream(ctx, messages, opts, func(token string) {
		receivedAnyToken = true
		if !strings.HasPrefix(token, "\x01") {
			fullResponse += token
		}
		stream.push(token)
	})
	if err != nil {
		return result, err
	}

	// Treat a completely silent response as failure (no tokens at all) so the
	// fallback chain tries the next model. This catches LM Studio returning
	// HTTP 200 with an empty stream when a model can't load.
	// We do NOT fail on thinking-only responses (receivedAnyToken=true but
	// fullResponse="") — those are valid Qwen3-style reasoning outputs.
	if !receivedAnyToken {
		return result, fmt.Errorf("model returned empty response")
	}

	trimmed := strings.TrimSpace(fullResponse)
	h.db.AddChatMessage(db.ChatMessage{
		CaptureID: job.CaptureID,
		Role:      "assistant",
		Content:   trimmed,
	})

	// Mirror the assistant turn into the notebook as a response cell.
	var skillPtr *string
	if job.SkillName != nil && *job.SkillName != "" {
		skillPtr = job.SkillName
	}
	cell := db.NotebookCell{
		Kind:      db.CellResponse,
		Content:   trimmed,
		SkillName: skillPtr,
	}
	h.db.AppendCellByCapture(job.CaptureID, cell)

	return result, nil
}

func buildMessages(job *db.Job, capture *db.Capture, history []db.ChatMessage, sendImage bool) []llm.Message {
	var messages []llm.Message

	if job.MasterPrompt != "" {
		messages = append(messages, llm.TextMessage(llm.RoleSystem, job.MasterPrompt))
	}
	if job.SkillPrompt != nil && *job.SkillPrompt != "" {
		messages = append(messages, llm.TextMessage(llm.RoleSystem, *job.SkillPrompt))
	}

	text := buildCaptureContext(capture, job.SendOCR)
	if sendImage && capture.ImagePath != "" {
		imgData, err := os.ReadFile(capture.ImagePath)
		if err == nil {
			imgBase64 := base64.StdEncoding.EncodeToString(imgData)
			messages = append(messages, llm.VisionMessage(llm.RoleUser, text, imgBase64))
		} else {
			log.Printf("could not load capture image %s: %v", capture.ImagePath, err)
			messages = append(messages, llm.TextMessage(llm.RoleUser, text))
		}
	} else {
		messages = append(messages, llm.TextMessage(llm.RoleUser, text))
	}

	for _, m := range history {
		if m.Role == "system" {
			continue
		}
		role := llm.RoleUser
		if m.Role == "assistant" {
			role = llm.RoleAssistant
		}
		messages = append(messages, llm.TextMessage(role, m.Content))
	}

	return messages
}

func buildCaptureContext(capture *db.Capture, sendOCR bool) string {
	var sb strings.Builder
	sb.WriteString("Analyze this screenshot.\n")
	if capture.AppName != nil {
		sb.WriteString("Application: " + *capture.AppName + "\n")
	}
	if capture.WindowTitle != nil {
		sb.WriteString("Window: " + *capture.WindowTitle + "\n")
	}
	if sendOCR && capture.OCRText != "" {
		sb.WriteString("\nText visible on screen:\n" + capture.OCRText)
	}
	return sb.String()
}
