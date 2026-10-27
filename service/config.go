//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// config mirrors service.json. It says what to run and which files to watch.
type config struct {
	App    string   `json:"app"`
	Args   []string `json:"args"`
	LogDir string   `json:"logDir"`
	Watch  []string `json:"watch"`
}

func loadConfig(path string) (config, error) {
	var cfg config

	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}

	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, err
	}

	if cfg.App == "" {
		return cfg, fmt.Errorf("missing app")
	}

	if cfg.LogDir == "" {
		cfg.LogDir = filepath.Dir(path)
	}

	return cfg, nil
}
