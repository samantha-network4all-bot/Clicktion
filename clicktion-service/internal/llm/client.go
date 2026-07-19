package llm

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

type Client struct {
	BaseURL   string
	APIKey    string
	ModelName string
	HTTP      *http.Client
}

func NewClient(baseURL, apiKey, modelName string) *Client {
	return &Client{
		// Trim surrounding whitespace (a stray space/tab pasted into the model
		// form otherwise produces an unparseable URL) before the trailing slash.
		BaseURL:   strings.TrimRight(strings.TrimSpace(baseURL), "/"),
		APIKey:    strings.TrimSpace(apiKey),
		ModelName: strings.TrimSpace(modelName),
		HTTP:      &http.Client{Timeout: 120 * time.Second},
	}
}

// Message roles
const (
	RoleSystem    = "system"
	RoleUser      = "user"
	RoleAssistant = "assistant"
)

type Message struct {
	Role    string `json:"role"`
	Content any    `json:"content"` // string or []ContentPart
}

func TextMessage(role, text string) Message {
	return Message{Role: role, Content: text}
}

func VisionMessage(role, text, imageBase64 string) Message {
	return Message{
		Role: role,
		Content: []ContentPart{
			{Type: "text", Text: text},
			{Type: "image_url", ImageURL: &ImageURL{
				URL:    "data:image/png;base64," + imageBase64,
				Detail: "high",
			}},
		},
	}
}

type ContentPart struct {
	Type     string    `json:"type"`
	Text     string    `json:"text,omitempty"`
	ImageURL *ImageURL `json:"image_url,omitempty"`
}

type ImageURL struct {
	URL    string `json:"url"`
	Detail string `json:"detail,omitempty"`
}

// StreamOptions controls per-request LLM parameters from the master profile.
type StreamOptions struct {
	Temperature float64 // -1 = model default (omit from request)
	MaxTokens   int     // 0 = model default (omit from request)
}

type chatRequest struct {
	Model       string    `json:"model"`
	Messages    []Message `json:"messages"`
	Stream      bool      `json:"stream"`
	Temperature *float64  `json:"temperature,omitempty"`
	MaxTokens   *int      `json:"max_tokens,omitempty"`
}

// StreamResult carries timing info for logging.
type StreamResult struct {
	FullText         string
	PromptTokens     int
	CompletionTokens int
	LatencyMs        int
}

// Stream calls the LLM and delivers tokens to onToken one at a time.
// Returns after the stream closes or ctx is cancelled.
func (c *Client) Stream(ctx context.Context, messages []Message, opts StreamOptions, onToken func(string)) (StreamResult, error) {
	start := time.Now()

	llmReq := chatRequest{
		Model:    c.ModelName,
		Messages: messages,
		Stream:   true,
	}
	if opts.Temperature >= 0 {
		t := opts.Temperature
		llmReq.Temperature = &t
	}
	if opts.MaxTokens > 0 {
		llmReq.MaxTokens = &opts.MaxTokens
	}

	body, err := json.Marshal(llmReq)
	if err != nil {
		return StreamResult{}, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.BaseURL+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return StreamResult{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.APIKey)
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return StreamResult{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		var buf bytes.Buffer
		buf.ReadFrom(resp.Body)
		return StreamResult{}, fmt.Errorf("LLM returned %d: %s", resp.StatusCode, buf.String())
	}

	var result StreamResult
	scanner := bufio.NewScanner(resp.Body)
	// Increase buffer for large chunks (vision models can have big payloads)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		data := strings.TrimPrefix(line, "data: ")
		if data == "[DONE]" {
			break
		}
		token, thinkToken, usage := parseChunk(data)
		// Thinking tokens (reasoning_content) are prefixed with \x01 so the
		// Swift client can route them to the "thinking" display area.
		if thinkToken != "" {
			onToken("\x01" + thinkToken)
		}
		if token != "" {
			result.FullText += token
			result.CompletionTokens++
			onToken(token)
		}
		if usage != nil {
			result.PromptTokens = usage.PromptTokens
			result.CompletionTokens = usage.CompletionTokens
		}
	}
	result.LatencyMs = int(time.Since(start).Milliseconds())
	return result, scanner.Err()
}

// Complete is a non-streaming call. Used for skill pre-selection.
func (c *Client) Complete(ctx context.Context, messages []Message) (string, error) {
	maxTok := 64
	body, err := json.Marshal(chatRequest{
		Model:     c.ModelName,
		Messages:  messages,
		Stream:    false,
		MaxTokens: &maxTok,
	})
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.BaseURL+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.APIKey)
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	var payload struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return "", err
	}
	if len(payload.Choices) == 0 {
		return "", fmt.Errorf("no choices in response")
	}
	return strings.TrimSpace(payload.Choices[0].Message.Content), nil
}

// chunk shapes from OpenAI SSE (supports Qwen3-style reasoning_content)
type chunk struct {
	Choices []struct {
		Delta struct {
			Content          string `json:"content"`
			ReasoningContent string `json:"reasoning_content"`
		} `json:"delta"`
		FinishReason *string `json:"finish_reason"`
	} `json:"choices"`
	Usage *usageInfo `json:"usage"`
}

type usageInfo struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
}

func parseChunk(data string) (token, thinkToken string, usage *usageInfo) {
	var c chunk
	if err := json.Unmarshal([]byte(data), &c); err != nil {
		return "", "", nil
	}
	if len(c.Choices) > 0 {
		token = c.Choices[0].Delta.Content
		thinkToken = c.Choices[0].Delta.ReasoningContent
	}
	return token, thinkToken, c.Usage
}
