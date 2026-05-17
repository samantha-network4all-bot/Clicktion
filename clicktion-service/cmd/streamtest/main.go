// streamtest: measures timing between SSE tokens from the clicktion service.
// Usage: go run ./cmd/streamtest
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

const baseURL = "http://localhost:8080"

func main() {
	key := mustReadFile(os.Getenv("HOME") + "/Library/Application Support/Clicktion/.apikey")

	// 1. Start a job against the most recent capture with a simple prompt
	captureID := mostRecentCapture(key)
	fmt.Printf("Using capture: %s\n", captureID)

	jobID := startJob(key, captureID)
	fmt.Printf("Job started:   %s\n\n", jobID)

	// 2. Stream and timestamp every token
	streamAndTime(key, jobID)
}

// ---------- helpers ----------

func mustReadFile(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		fatalf("read %s: %v", path, err)
	}
	return strings.TrimSpace(string(b))
}

func get(key, path string) []byte {
	req, _ := http.NewRequest("GET", baseURL+path, nil)
	req.Header.Set("Authorization", "Bearer "+key)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fatalf("GET %s: %v", path, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return b
}

func post(key, path string, body any) []byte {
	data, _ := json.Marshal(body)
	req, _ := http.NewRequest("POST", baseURL+path, bytes.NewReader(data))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fatalf("POST %s: %v", path, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return b
}

func mostRecentCapture(key string) string {
	var captures []struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(get(key, "/api/captures"), &captures); err != nil || len(captures) == 0 {
		fatalf("no captures found")
	}
	return captures[0].ID
}

func startJob(key, captureID string) string {
	body := map[string]any{
		"capture_id":   captureID,
		"skill_name":   "stream-test",
		"skill_prompt": "Reply with exactly 20 short words, one idea per word. Be concise.",
		"send_image":   false,
	}
	var job struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(post(key, "/api/jobs", body), &job); err != nil || job.ID == "" {
		fatalf("start job failed")
	}
	return job.ID
}

func streamAndTime(key, jobID string) {
	req, _ := http.NewRequest("GET", baseURL+"/api/jobs/"+jobID+"/stream", nil)
	req.Header.Set("Authorization", "Bearer "+key)

	// Use a client with no timeout for the stream
	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		fatalf("stream connect: %v", err)
	}
	defer resp.Body.Close()

	fmt.Printf("%-6s  %-10s  %s\n", "TOKEN", "SINCE_PREV", "CONTENT")
	fmt.Println(strings.Repeat("-", 60))

	scanner := bufio.NewScanner(resp.Body)
	var last time.Time
	n := 0
	var pending string
	var gaps []time.Duration

	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "data: ") {
			chunk := strings.TrimPrefix(line, "data: ")
			if chunk == "[DONE]" {
				if pending != "" {
					printToken(&n, &last, &gaps, pending)
					pending = ""
				}
				break
			}
			pending = pending + chunk
		} else if line == "" && pending != "" {
			printToken(&n, &last, &gaps, pending)
			pending = ""
		}
	}

	if err := scanner.Err(); err != nil {
		fmt.Printf("\nscanner error: %v\n", err)
	}

	// Summary
	fmt.Println(strings.Repeat("-", 60))
	fmt.Printf("Total tokens: %d\n", n)
	if len(gaps) > 1 {
		var total time.Duration
		min, max := gaps[1], gaps[1]
		for _, g := range gaps[1:] { // skip first (no previous)
			total += g
			if g < min { min = g }
			if g > max { max = g }
		}
		avg := total / time.Duration(len(gaps)-1)
		fmt.Printf("Gap min/avg/max: %v / %v / %v\n", min.Round(time.Microsecond), avg.Round(time.Microsecond), max.Round(time.Microsecond))
		if max < 2*time.Millisecond {
			fmt.Println("\n⚠  All tokens arrived within 2ms — they were batched in one network delivery.")
			fmt.Println("   The LLM server is likely not streaming token-by-token to the Go service.")
		} else {
			fmt.Println("\n✓  Gaps detected — tokens are arriving with spacing, streaming is working.")
		}
	}
}

func printToken(n *int, last *time.Time, gaps *[]time.Duration, token string) {
	now := time.Now()
	var since time.Duration
	if !last.IsZero() {
		since = now.Sub(*last)
	}
	*last = now
	*gaps = append(*gaps, since)
	*n++

	preview := token
	if strings.HasPrefix(preview, "\x01") {
		preview = "[think] " + preview[1:]
	}
	if len(preview) > 40 {
		preview = preview[:37] + "..."
	}
	if *n == 1 {
		fmt.Printf("%-6d  %-10s  %s\n", *n, "—", preview)
	} else {
		fmt.Printf("%-6d  %-10s  %s\n", *n, since.Round(time.Microsecond), preview)
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "FATAL: "+format+"\n", args...)
	os.Exit(1)
}
