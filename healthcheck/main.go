package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	_ "github.com/go-sql-driver/mysql"
	"github.com/redis/go-redis/v9"
)

type ServiceStatus struct {
	Name    string `json:"name"`
	Healthy bool   `json:"healthy"`
	Latency string `json:"latency,omitempty"`
	Error   string `json:"error,omitempty"`
}

type HealthResponse struct {
	Overall  bool            `json:"overall"`
	Services []ServiceStatus `json:"services"`
}

func checkRedis(ctx context.Context) ServiceStatus {
	addr := os.Getenv("REDIS_ADDR")
	if addr == "" {
		addr = "redis:6379"
	}

	start := time.Now()
	rdb := redis.NewClient(&redis.Options{Addr: addr})
	defer rdb.Close()

	err := rdb.Ping(ctx).Err()
	latency := time.Since(start)

	if err != nil {
		return ServiceStatus{Name: "redis", Healthy: false, Error: err.Error()}
	}
	return ServiceStatus{Name: "redis", Healthy: true, Latency: latency.String()}
}

func checkMySQL(ctx context.Context) ServiceStatus {
	dsn := os.Getenv("MYSQL_DSN")
	if dsn == "" {
		dsn = "app:apppass@tcp(mysql:3306)/testdb"
	}

	start := time.Now()
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return ServiceStatus{Name: "mysql", Healthy: false, Error: err.Error()}
	}
	defer db.Close()

	err = db.PingContext(ctx)
	latency := time.Since(start)

	if err != nil {
		return ServiceStatus{Name: "mysql", Healthy: false, Error: err.Error()}
	}
	return ServiceStatus{Name: "mysql", Healthy: true, Latency: latency.String()}
}

func checkHTTP(ctx context.Context, name, url string) ServiceStatus {
	start := time.Now()
	req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
	resp, err := http.DefaultClient.Do(req)
	latency := time.Since(start)

	if err != nil {
		return ServiceStatus{Name: name, Healthy: false, Error: err.Error()}
	}
	defer resp.Body.Close()

	healthy := resp.StatusCode == http.StatusOK
	s := ServiceStatus{Name: name, Healthy: healthy, Latency: latency.String()}
	if !healthy {
		s.Error = fmt.Sprintf("status %d", resp.StatusCode)
	}
	return s
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	services := []ServiceStatus{
		checkRedis(ctx),
		checkMySQL(ctx),
		checkHTTP(ctx, "api", os.Getenv("API_URL")),
		checkHTTP(ctx, "worker", os.Getenv("WORKER_URL")),
	}

	overall := true
	for _, s := range services {
		if !s.Healthy {
			overall = false
			break
		}
	}

	resp := HealthResponse{Overall: overall, Services: services}

	w.Header().Set("Content-Type", "application/json")
	if !overall {
		w.WriteHeader(http.StatusServiceUnavailable)
	}
	json.NewEncoder(w).Encode(resp)
}

func main() {
	http.HandleFunc("/health", healthHandler)
	log.Println("Healthcheck dashboard listening on :9090")
	log.Fatal(http.ListenAndServe(":9090", nil))
}
