package llm

import "strings"

// SupportsVision guesses whether a model can accept images, from its name.
// Best-effort — OpenAI-compatible endpoints don't advertise capabilities.
func SupportsVision(modelName string) bool {
	n := strings.ToLower(modelName)
	for _, k := range []string{
		"vl", "vision", "llava", "moondream", "minicpm-v",
		"pixtral", "internvl", "gemma-3", "gemma3", "vlm",
	} {
		if strings.Contains(n, k) {
			return true
		}
	}
	return false
}

// SupportsThinking guesses whether a model emits reasoning/thinking output.
func SupportsThinking(modelName string) bool {
	n := strings.ToLower(modelName)
	for _, k := range []string{
		"qwq", "-r1", "r1-", "deepseek-r1", "reason",
		"thinking", "magistral", "qwen3", "o1", "o3",
	} {
		if strings.Contains(n, k) {
			return true
		}
	}
	return false
}
