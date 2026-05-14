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
		BaseURL:   strings.TrimRight(baseURL, "/"),
		APIKey:    apiKey,
		ModelName: modelName,
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

type Request struct {
	Model     string    `json:"model"`
	Messages  []Message `json:"messages"`
	Stream    bool      `json:"stream"`
	MaxTokens int       `json:"max_tokens,omitempty"`
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
func (c *Client) Stream(ctx context.Context, messages []Message, onToken func(string)) (StreamResult, error) {
	start := time.Now()

	body, err := json.Marshal(Request{
		Model:    c.ModelName,
		Messages: messages,
		Stream:   true,
	})
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
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		data := strings.TrimPrefix(line, "data: ")
		if data == "[DONE]" {
			break
		}
		token, usage := parseChunk(data)
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
	body, err := json.Marshal(Request{
		Model:     c.ModelName,
		Messages:  messages,
		Stream:    false,
		MaxTokens: 64,
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

// chunk shapes from OpenAI SSE
type chunk struct {
	Choices []struct {
		Delta struct {
			Content string `json:"content"`
		} `json:"delta"`
		FinishReason *string `json:"finish_reason"`
	} `json:"choices"`
	Usage *usageInfo `json:"usage"`
}

type usageInfo struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
}

func parseChunk(data string) (token string, usage *usageInfo) {
	var c chunk
	if err := json.Unmarshal([]byte(data), &c); err != nil {
		return "", nil
	}
	if len(c.Choices) > 0 {
		token = c.Choices[0].Delta.Content
	}
	return token, c.Usage
}
