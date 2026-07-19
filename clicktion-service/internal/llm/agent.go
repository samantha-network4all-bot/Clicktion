package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
)

// Tool is an OpenAI-compatible function tool definition.
type Tool struct {
	Type     string       `json:"type"` // always "function"
	Function ToolFunction `json:"function"`
}

type ToolFunction struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Parameters  json.RawMessage `json:"parameters"` // JSON schema object
}

// ToolCall is a function call requested by the model.
type ToolCall struct {
	ID       string `json:"id"`
	Type     string `json:"type"`
	Function struct {
		Name      string `json:"name"`
		Arguments string `json:"arguments"` // JSON-encoded arguments
	} `json:"function"`
}

// AgentMessage extends the chat message with tool-calling fields.
type AgentMessage struct {
	Role       string     `json:"role"`
	Content    string     `json:"content,omitempty"`
	ToolCalls  []ToolCall `json:"tool_calls,omitempty"`
	ToolCallID string     `json:"tool_call_id,omitempty"`
	Name       string     `json:"name,omitempty"`
}

// AgentTurn is one assistant response: free text and/or tool calls.
type AgentTurn struct {
	Content   string     `json:"content"`
	ToolCalls []ToolCall `json:"tool_calls"`
}

type agentRequest struct {
	Model     string         `json:"model"`
	Messages  []AgentMessage `json:"messages"`
	Tools     []Tool         `json:"tools,omitempty"`
	Stream    bool           `json:"stream"`
	MaxTokens *int           `json:"max_tokens,omitempty"`
}

// CompleteWithTools runs one non-streaming, tool-enabled turn.
func (c *Client) CompleteWithTools(ctx context.Context, messages []AgentMessage, tools []Tool) (AgentTurn, error) {
	body, err := json.Marshal(agentRequest{
		Model:    c.ModelName,
		Messages: messages,
		Tools:    tools,
		Stream:   false,
	})
	if err != nil {
		return AgentTurn{}, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		c.BaseURL+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return AgentTurn{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.APIKey)
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return AgentTurn{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		var buf bytes.Buffer
		buf.ReadFrom(resp.Body)
		return AgentTurn{}, fmt.Errorf("LLM returned %d: %s", resp.StatusCode, buf.String())
	}

	var payload struct {
		Choices []struct {
			Message struct {
				Content   string     `json:"content"`
				ToolCalls []ToolCall `json:"tool_calls"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return AgentTurn{}, err
	}
	if len(payload.Choices) == 0 {
		return AgentTurn{}, fmt.Errorf("no choices in response")
	}
	msg := payload.Choices[0].Message
	return AgentTurn{Content: msg.Content, ToolCalls: msg.ToolCalls}, nil
}
