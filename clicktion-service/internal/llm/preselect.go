package llm

import (
	"context"
	"fmt"
	"strings"
)

type SkillInfo struct {
	Name     string   `json:"name"`
	Triggers []string `json:"triggers"`
}

// SelectSkill asks the LLM to pick the best skill for the given context.
// Returns the skill name or empty string if it cannot decide.
func SelectSkill(ctx context.Context, c *Client, skills []SkillInfo, appName, windowTitle, ocrSample string) string {
	if len(skills) == 0 {
		return ""
	}

	var sb strings.Builder
	sb.WriteString("You are a task classifier for a screenshot analysis tool.\n\n")
	sb.WriteString("Available skills:\n")
	for _, s := range skills {
		sb.WriteString(fmt.Sprintf("- %s (keywords: %s)\n", s.Name, strings.Join(s.Triggers, ", ")))
	}
	sb.WriteString("\nContext:\n")
	if appName != "" {
		sb.WriteString(fmt.Sprintf("Application: %s\n", appName))
	}
	if windowTitle != "" {
		sb.WriteString(fmt.Sprintf("Window: %s\n", windowTitle))
	}
	if ocrSample != "" {
		sample := ocrSample
		if len(sample) > 400 {
			sample = sample[:400] + "…"
		}
		sb.WriteString(fmt.Sprintf("Screen text: %s\n", sample))
	}
	sb.WriteString("\nRespond with ONLY the exact skill name from the list above. No explanation, no punctuation.")

	result, err := c.Complete(ctx, []Message{
		TextMessage(RoleSystem, sb.String()),
	})
	if err != nil {
		return ""
	}

	// Match against known skill names (case-insensitive)
	for _, s := range skills {
		if strings.EqualFold(result, s.Name) {
			return s.Name
		}
	}
	// Partial match fallback
	for _, s := range skills {
		if strings.Contains(strings.ToLower(result), strings.ToLower(s.Name)) {
			return s.Name
		}
	}
	return ""
}
