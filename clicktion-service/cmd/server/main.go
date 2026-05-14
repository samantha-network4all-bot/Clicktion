package main

import (
	"log"
	"net/http"
	"os"

	"github.com/clicktion/service/internal/api"
	"github.com/clicktion/service/internal/db"
)

func main() {
	dataDir := dataDirectory()
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		log.Fatalf("create data dir: %v", err)
	}

	database, err := db.Open(dataDir + "/clicktion.db")
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	defer database.Close()

	if err := database.Migrate(); err != nil {
		log.Fatalf("migrate: %v", err)
	}

	addr := os.Getenv("CLICKTION_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8080"
	}

	router := api.NewRouter(database, dataDir)
	log.Printf("clicktion-service listening on %s", addr)
	if err := http.ListenAndServe(addr, router); err != nil {
		log.Fatalf("serve: %v", err)
	}
}

func dataDirectory() string {
	if d := os.Getenv("CLICKTION_DATA_DIR"); d != "" {
		return d
	}
	home, _ := os.UserHomeDir()
	return home + "/Library/Application Support/Clicktion"
}
