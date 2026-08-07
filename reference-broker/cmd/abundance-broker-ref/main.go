package main

import (
	"log"
	"net/http"
	"os"
	"time"

	broker "github.com/abundance-company/abundance-swift-sdk/reference-broker"
)

// Configuration is environment-only — no flags. The variable names double as
// the config file format: deploy/broker.env.example documents every one, and
// callers source such a file or import it (flyctl secrets).
func main() {
	listenAddress := environmentOr("ABUNDANCE_BROKER_LISTEN", ":8080")
	storageDir := environmentOr("ABUNDANCE_BROKER_STORAGE_DIR", "./broker-data")
	token := os.Getenv("ABUNDANCE_BROKER_TOKEN")
	s3Bucket := os.Getenv("ABUNDANCE_S3_BUCKET")
	if token == "" {
		log.Fatal("ABUNDANCE_BROKER_TOKEN is required (see deploy/broker.env.example)")
	}

	var s3 *broker.S3Store
	if s3Bucket != "" {
		var err error
		s3, err = broker.NewS3Store(broker.S3Configuration{
			Bucket:          s3Bucket,
			Region:          environmentOr("AWS_REGION", os.Getenv("AWS_DEFAULT_REGION")),
			Endpoint:        os.Getenv("ABUNDANCE_S3_ENDPOINT"),
			Prefix:          os.Getenv("ABUNDANCE_S3_PREFIX"),
			AccessKeyID:     os.Getenv("AWS_ACCESS_KEY_ID"),
			SecretAccessKey: os.Getenv("AWS_SECRET_ACCESS_KEY"),
			SessionToken:    os.Getenv("AWS_SESSION_TOKEN"),
		})
		if err != nil {
			log.Fatal(err)
		}
	}

	handler := broker.NewReferenceBrokerWithS3(storageDir, token, log.Default(), s3)
	log.Printf("Reference broker listening on %s with storage %s", listenAddress, storageDir)
	// Do not set ReadTimeout or WriteTimeout: artifact PUTs are multi-gigabyte
	// over ~1.3 MB/s uplinks and legitimately run for hours.
	server := &http.Server{
		Addr:              listenAddress,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

func environmentOr(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
