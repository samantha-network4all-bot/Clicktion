package db

import "time"

type Job struct {
	ID          string
	CaptureID   string
	ModelID     *string
	SkillName   *string
	SkillPrompt *string
	SendImage   bool // whether to include the screenshot in the LLM request
	Status      string // pending | running | done | failed
	CreatedAt   time.Time
	FinishedAt  *time.Time
}

type ChatMessage struct {
	ID        string
	CaptureID string
	Role      string // user | assistant | system
	Content   string
	CreatedAt time.Time
}

type LLMLog struct {
	ID               string
	JobID            string
	ModelName        string
	PromptTokens     int
	CompletionTokens int
	LatencyMs        int
	Error            *string
	CreatedAt        time.Time
}

// Jobs

func (d *DB) CreateJob(j Job) (Job, error) {
	j.ID = newID()
	sendImage := 1
	if !j.SendImage {
		sendImage = 0
	}
	_, err := d.sql.Exec(`
		INSERT INTO jobs (id, capture_id, model_id, skill_name, skill_prompt, send_image, status)
		VALUES (?, ?, ?, ?, ?, ?, 'pending')`,
		j.ID, j.CaptureID, j.ModelID, j.SkillName, j.SkillPrompt, sendImage)
	return j, err
}

func (d *DB) GetJob(id string) (*Job, error) {
	var j Job
	var sendImage int
	err := d.sql.QueryRow(`
		SELECT id, capture_id, model_id, skill_name, skill_prompt, send_image, status, created_at, finished_at
		FROM jobs WHERE id = ?`, id).Scan(
		&j.ID, &j.CaptureID, &j.ModelID, &j.SkillName, &j.SkillPrompt, &sendImage,
		&j.Status, &j.CreatedAt, &j.FinishedAt)
	if err != nil {
		return nil, err
	}
	j.SendImage = sendImage != 0
	return &j, nil
}

func (d *DB) UpdateJobStatus(id, status string) error {
	if status == "done" || status == "failed" {
		_, err := d.sql.Exec(
			`UPDATE jobs SET status = ?, finished_at = CURRENT_TIMESTAMP WHERE id = ?`, status, id)
		return err
	}
	_, err := d.sql.Exec(`UPDATE jobs SET status = ? WHERE id = ?`, status, id)
	return err
}

// Chat messages

func (d *DB) AddChatMessage(m ChatMessage) (ChatMessage, error) {
	m.ID = newID()
	_, err := d.sql.Exec(`
		INSERT INTO chat_messages (id, capture_id, role, content)
		VALUES (?, ?, ?, ?)`, m.ID, m.CaptureID, m.Role, m.Content)
	return m, err
}

func (d *DB) ListChatMessages(captureID string) ([]ChatMessage, error) {
	rows, err := d.sql.Query(`
		SELECT id, capture_id, role, content, created_at
		FROM chat_messages WHERE capture_id = ? ORDER BY created_at`, captureID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ChatMessage
	for rows.Next() {
		var m ChatMessage
		if err := rows.Scan(&m.ID, &m.CaptureID, &m.Role, &m.Content, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// LLM logs

func (d *DB) AddLLMLog(l LLMLog) error {
	l.ID = newID()
	_, err := d.sql.Exec(`
		INSERT INTO llm_logs (id, job_id, model_name, prompt_tokens, completion_tokens, latency_ms, error)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		l.ID, l.JobID, l.ModelName, l.PromptTokens, l.CompletionTokens, l.LatencyMs, l.Error)
	return err
}
