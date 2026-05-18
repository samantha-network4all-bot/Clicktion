// Package skills reads skill definitions from <dataDir>/skills/ on disk.
// Each skill is two files: name.md (frontmatter + system prompt) and an
// optional name.json (permissions, not used server-side yet).
//
// The on-disk format matches what the Mac app's SkillLoader writes — see
// Sources/Clicktion/Skills/SkillLoader.swift.
package skills

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type Skill struct {
	Filename     string // base name without extension, used as a slug
	Name         string
	Icon         string
	Triggers     []string
	SystemPrompt string
	InputMode    string // "image_and_text" | "image_only" | "text_only"
}

// LoadAll reads every .md file in dir and returns the parsed skills,
// sorted by display name.
func LoadAll(dir string) ([]Skill, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var out []Skill
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
			continue
		}
		path := filepath.Join(dir, e.Name())
		s, err := loadFile(path)
		if err != nil {
			continue // skip unparseable files rather than aborting the list
		}
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool {
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out, nil
}

// FindByName looks up a skill by its display name (case-sensitive). Returns
// nil if no skill matches.
func FindByName(dir, name string) (*Skill, error) {
	all, err := LoadAll(dir)
	if err != nil {
		return nil, err
	}
	for _, s := range all {
		if s.Name == name {
			return &s, nil
		}
	}
	return nil, nil
}

func loadFile(path string) (Skill, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return Skill{}, err
	}
	base := strings.TrimSuffix(filepath.Base(path), ".md")
	s := Skill{Filename: base, Name: base, Icon: "sparkles", InputMode: "image_and_text"}

	text := string(raw)
	if !strings.HasPrefix(text, "---") {
		s.SystemPrompt = strings.TrimSpace(text)
		return s, nil
	}

	lines := strings.Split(text, "\n")
	bodyStart := 0
	for i := 1; i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) == "---" {
			bodyStart = i + 1
			break
		}
		parts := strings.SplitN(lines[i], ":", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		val := strings.TrimSpace(parts[1])
		switch key {
		case "name":
			s.Name = val
		case "icon":
			s.Icon = val
		case "triggers":
			for _, t := range strings.Split(val, ",") {
				if t = strings.TrimSpace(t); t != "" {
					s.Triggers = append(s.Triggers, t)
				}
			}
		case "input_mode":
			s.InputMode = val
		}
	}
	s.SystemPrompt = strings.TrimSpace(strings.Join(lines[bodyStart:], "\n"))
	return s, nil
}
