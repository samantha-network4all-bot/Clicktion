package api

import (
	"encoding/json"
	"fmt"
	"net/http"
)

func jsonOK(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func httpError(w http.ResponseWriter, err error, code int) {
	http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), code)
}
