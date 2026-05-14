package api

import (
	"context"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/clicktion/service/internal/db"
	"github.com/clicktion/service/internal/llm"
)

// jobStream holds buffered tokens for an active LLM call.
// SSE handlers poll this; it is removed from activeStreams when done.
type jobStream struct {
	mu     sync.Mutex
	tokens []string
	done   bool
	err    error
}

func (s *jobStream) push(token string) {
	s.mu.Lock()
	s.tokens = append(s.tokens, token)
	s.mu.Unlock()
}

func (s *jobStream) snapshot() ([]string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]string, len(s.tokens))
	copy(out, s.tokens)
	return out, s.done
}

var activeStreams sync.Map // string(jobID) → *jobStream

// runJob executes the LLM call for a job in a goroutine.
// It tries each model in the fallback chain.
func (h *handler) runJob(jobID string) {
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()

		stream := &jobStream{}
		activeStreams.Store(jobID, stream)
		defer activeStreams.Delete(jobID)

		if err := h.executeJob(ctx, jobID, stream); err != nil {
			log.Printf("job %s failed: %v", jobID, err)
			stream.mu.Lock()
			stream.err = err
			stream.done = true
			stream.mu.Unlock()
			h.db.UpdateJobStatus(jobID, "failed")
			return
		}

		stream.mu.Lock()
		stream.done = true
		stream.mu.Unlock()
		h.db.UpdateJobStatus(jobID, "done")
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

	// Build message history
	history, err := h.db.ListChatMessages(job.CaptureID)
	if err != nil {
		return err
	}

	// Pick model — enforce local-only for private captures
	models, err := h.db.FallbackChain(capture.IsPrivate)
	if err != nil || len(models) == 0 {
		return fmt.Errorf("no suitable model configured")
	}

	var lastErr error
	for i, model := range models {
		client := llm.NewClient(model.BaseURL, model.APIKey, model.ModelName)
		result, err := h.streamWithModel(ctx, client, job, capture, history, stream, i > 0)
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
		// Notify via a special SSE token that we're falling back
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
) (llm.StreamResult, error) {
	messages := buildMessages(job, capture, history)

	var fullResponse string
	result, err := client.Stream(ctx, messages, func(token string) {
		fullResponse += token
		stream.push(token)
	})
	if err != nil {
		return result, err
	}

	// Persist the assistant response
	h.db.AddChatMessage(db.ChatMessage{
		CaptureID: job.CaptureID,
		Role:      "assistant",
		Content:   fullResponse,
	})

	return result, nil
}

func buildMessages(job *db.Job, capture *db.Capture, history []db.ChatMessage) []llm.Message {
	var messages []llm.Message

	// System prompt from the skill
	if job.SkillPrompt != nil && *job.SkillPrompt != "" {
		messages = append(messages, llm.TextMessage(llm.RoleSystem, *job.SkillPrompt))
	}

	// If this is the first turn, inject the capture context as the first user message
	if len(history) == 0 {
		context := buildCaptureContext(capture)
		if capture.ImagePath != "" {
			// TODO: load image bytes and send as vision message
			messages = append(messages, llm.TextMessage(llm.RoleUser, context))
		} else {
			messages = append(messages, llm.TextMessage(llm.RoleUser, context))
		}
	} else {
		// Replay history
		for _, m := range history {
			role := llm.RoleUser
			if m.Role == "assistant" {
				role = llm.RoleAssistant
			}
			messages = append(messages, llm.TextMessage(role, m.Content))
		}
	}

	return messages
}

func buildCaptureContext(capture *db.Capture) string {
	var sb strings.Builder
	if capture.AppName != nil {
		sb.WriteString("Application: " + *capture.AppName + "\n")
	}
	if capture.WindowTitle != nil {
		sb.WriteString("Window: " + *capture.WindowTitle + "\n")
	}
	if capture.OCRText != "" {
		sb.WriteString("\nScreen text:\n" + capture.OCRText)
	}
	return sb.String()
}
