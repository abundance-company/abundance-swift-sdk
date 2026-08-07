// Package broker is the Station upload Reference broker: the three-endpoint
// service (announce, artifact PUT, complete) a device uploads finished
// sessions to, exactly as documented in the A4 device API reference and
// mirrored by AbundanceBroker.swift. Import it into your own service or run
// ./cmd/abundance-broker-ref as-is. It is a reference, never a production
// Broker: storage is local disk, or S3-compatible via presigned URLs.
package broker

import (
	"bytes"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	announcementFilename = "announcement.json"
	artifactDirectory    = "artifacts"
)

type announcedArtifact struct {
	Name   string `json:"name"`
	Bytes  int64  `json:"bytes"`
	SHA256 string `json:"sha256"`
}

type announcedSegment struct {
	Index  int               `json:"index"`
	Video  announcedArtifact `json:"video"`
	IMU    announcedArtifact `json:"imu"`
	Frames announcedArtifact `json:"frames"`
}

type sessionAnnouncement struct {
	SessionID string              `json:"session_id"`
	DeviceID  string              `json:"device_id"`
	Segments  []announcedSegment  `json:"segments"`
	Logs      []announcedArtifact `json:"logs"`
}

type artifactDestination struct {
	Name    string            `json:"name"`
	Method  string            `json:"method"`
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers"`
}

type uploadPlan struct {
	Uploads     []artifactDestination `json:"uploads"`
	CompleteURL string                `json:"complete_url"`
	ExpiresAt   int64                 `json:"expires_at"`
}

type uploadedArtifact struct {
	Name   string `json:"name"`
	SHA256 string `json:"sha256"`
}

type completionReport struct {
	SessionID string             `json:"session_id"`
	Uploaded  []uploadedArtifact `json:"uploaded"`
}

type referenceBroker struct {
	storageDir string
	token      string
	logger     *log.Logger
	routes     *http.ServeMux
	s3         *S3Store
}

type loggedResponse struct {
	http.ResponseWriter
	status  int
	session string
}

// NewReferenceBroker serves the broker contract with artifacts stored on
// local disk under storageDir.
func NewReferenceBroker(storageDir, token string, logger *log.Logger) *referenceBroker {
	return NewReferenceBrokerWithS3(storageDir, token, logger, nil)
}

// NewReferenceBrokerWithS3 additionally presigns artifact destinations
// against s3 when non-nil; announcements stay on local disk either way.
func NewReferenceBrokerWithS3(storageDir, token string, logger *log.Logger, s3 *S3Store) *referenceBroker {
	b := &referenceBroker{
		storageDir: storageDir,
		token:      token,
		logger:     logger,
		routes:     http.NewServeMux(),
		s3:         s3,
	}
	b.routes.HandleFunc("POST /sessions", b.announceSession)
	b.routes.HandleFunc("PUT /sessions/{session}/artifacts/{artifact}", b.storeArtifact)
	b.routes.HandleFunc("POST /sessions/{session}/complete", b.completeSession)
	return b
}

func (b *referenceBroker) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	response := &loggedResponse{ResponseWriter: w, status: http.StatusOK, session: "-"}
	b.routes.ServeHTTP(response, r)
	b.logger.Printf("method=%s path=%s session=%s outcome=%d", r.Method, r.URL.Path, response.session, response.status)
}

func (w *loggedResponse) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (w *loggedResponse) Write(body []byte) (int, error) {
	return w.ResponseWriter.Write(body)
}

func (b *referenceBroker) announceSession(w http.ResponseWriter, r *http.Request) {
	if !b.authorizeDevice(w, r) {
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 8<<20)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		status := http.StatusBadRequest
		var maximumBytesError *http.MaxBytesError
		if errors.As(err, &maximumBytesError) {
			status = http.StatusRequestEntityTooLarge
		}
		http.Error(w, "read announcement", status)
		return
	}
	var announcement sessionAnnouncement
	if err := json.Unmarshal(body, &announcement); err != nil {
		http.Error(w, "invalid announcement JSON", http.StatusBadRequest)
		return
	}
	markSession(w, announcement.SessionID)
	if !safePathName(announcement.SessionID) || announcement.DeviceID == "" || announcement.DeviceID != r.Header.Get("X-Abundance-Device-Id") {
		http.Error(w, "invalid session or device id", http.StatusBadRequest)
		return
	}
	artifacts, err := flattenArtifacts(announcement)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	var indented bytes.Buffer
	if err := json.Indent(&indented, body, "", "  "); err != nil {
		http.Error(w, "invalid announcement JSON", http.StatusBadRequest)
		return
	}
	indented.WriteByte('\n')
	if err := writeFileAtomically(b.announcementPath(announcement.SessionID), indented.Bytes(), 0o600); err != nil {
		http.Error(w, "store announcement", http.StatusInternalServerError)
		return
	}

	uploads := make([]artifactDestination, 0, len(artifacts))
	issuedAt := time.Now().UTC()
	for _, artifact := range artifacts {
		matches, err := b.artifactMatches(announcement.SessionID, artifact)
		if err != nil {
			http.Error(w, "inspect stored artifact", http.StatusBadGateway)
			return
		}
		if matches {
			continue
		}
		if b.s3 != nil {
			destination, err := b.s3.destination(announcement.SessionID, artifact, issuedAt)
			if err != nil {
				http.Error(w, "presign artifact destination", http.StatusInternalServerError)
				return
			}
			uploads = append(uploads, destination)
			continue
		}
		// Destinations are opaque to the device: it sends exactly these
		// headers. Direct-PUT destinations therefore carry their own auth,
		// mirroring how a presigned S3 URL embeds its signature.
		uploads = append(uploads, artifactDestination{
			Name:   artifact.Name,
			Method: http.MethodPut,
			URL:    publicRequestURL(r, "/sessions/"+announcement.SessionID+"/artifacts/"+artifact.Name),
			Headers: map[string]string{
				"Content-Type":          contentTypeForArtifact(artifact.Name),
				"Authorization":         "Bearer " + b.token,
				"X-Abundance-Device-Id": r.Header.Get("X-Abundance-Device-Id"),
			},
		})
	}
	writeJSON(w, http.StatusOK, uploadPlan{
		Uploads:     uploads,
		CompleteURL: publicRequestURL(r, "/sessions/"+announcement.SessionID+"/complete"),
		ExpiresAt:   issuedAt.Add(presignLifetime).Unix(),
	})
}

func (b *referenceBroker) storeArtifact(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("session")
	artifactName := r.PathValue("artifact")
	markSession(w, sessionID)
	if !b.authorizeDevice(w, r) {
		return
	}
	if !safePathName(sessionID) || !safePathName(artifactName) {
		http.Error(w, "invalid artifact path", http.StatusBadRequest)
		return
	}
	announcement, err := b.readAnnouncement(sessionID)
	if errors.Is(err, os.ErrNotExist) {
		http.Error(w, "unknown session", http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, "read announcement", http.StatusInternalServerError)
		return
	}
	artifact, found := findArtifact(announcement, artifactName)
	if !found {
		http.Error(w, "unknown artifact", http.StatusNotFound)
		return
	}
	expectedHeader := r.Header.Get("X-Abundance-SHA256")
	if !validSHA256(expectedHeader) || !strings.EqualFold(expectedHeader, artifact.SHA256) {
		http.Error(w, "invalid artifact SHA-256", http.StatusBadRequest)
		return
	}

	artifactDir := filepath.Join(b.storageDir, sessionID, artifactDirectory)
	if err := os.MkdirAll(artifactDir, 0o700); err != nil {
		http.Error(w, "create artifact directory", http.StatusInternalServerError)
		return
	}
	temporary, err := os.CreateTemp(artifactDir, ".upload-*")
	if err != nil {
		http.Error(w, "create artifact", http.StatusInternalServerError)
		return
	}
	temporaryPath := temporary.Name()
	stored := false
	defer func() {
		temporary.Close()
		if !stored {
			os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		http.Error(w, "secure artifact", http.StatusInternalServerError)
		return
	}
	digest := sha256.New()
	written, err := io.Copy(io.MultiWriter(temporary, digest), io.LimitReader(r.Body, artifact.Bytes+1))
	if err != nil {
		http.Error(w, "store artifact", http.StatusBadRequest)
		return
	}
	if written > artifact.Bytes {
		http.Error(w, "artifact exceeds announced byte count", http.StatusBadRequest)
		return
	}
	if !strings.EqualFold(hex.EncodeToString(digest.Sum(nil)), expectedHeader) {
		http.Error(w, "artifact SHA-256 mismatch", http.StatusBadRequest)
		return
	}
	if err := temporary.Sync(); err != nil {
		http.Error(w, "sync artifact", http.StatusInternalServerError)
		return
	}
	if err := temporary.Close(); err != nil {
		http.Error(w, "close artifact", http.StatusInternalServerError)
		return
	}
	if err := os.Rename(temporaryPath, b.artifactPath(sessionID, artifactName)); err != nil {
		http.Error(w, "commit artifact", http.StatusInternalServerError)
		return
	}
	stored = true
	w.WriteHeader(http.StatusOK)
}

func (b *referenceBroker) completeSession(w http.ResponseWriter, r *http.Request) {
	sessionID := r.PathValue("session")
	markSession(w, sessionID)
	if !b.authorizeDevice(w, r) {
		return
	}
	if !safePathName(sessionID) {
		http.Error(w, "invalid session id", http.StatusBadRequest)
		return
	}
	var report completionReport
	if err := json.NewDecoder(r.Body).Decode(&report); err != nil {
		http.Error(w, "invalid completion JSON", http.StatusBadRequest)
		return
	}
	if report.SessionID != sessionID {
		http.Error(w, "session id does not match URL", http.StatusBadRequest)
		return
	}
	announcement, err := b.readAnnouncement(sessionID)
	if errors.Is(err, os.ErrNotExist) {
		http.Error(w, "unknown session", http.StatusNotFound)
		return
	}
	if err != nil {
		http.Error(w, "read announcement", http.StatusInternalServerError)
		return
	}
	artifacts, err := flattenArtifacts(announcement)
	if err != nil {
		http.Error(w, "invalid stored announcement", http.StatusInternalServerError)
		return
	}
	missing := make([]string, 0)
	for _, artifact := range artifacts {
		matches, err := b.artifactMatches(sessionID, artifact)
		if err != nil {
			http.Error(w, "inspect stored artifact", http.StatusBadGateway)
			return
		}
		if !matches {
			missing = append(missing, artifact.Name)
		}
	}
	if len(missing) != 0 {
		writeJSON(w, http.StatusConflict, struct {
			Missing []string `json:"missing"`
		}{Missing: missing})
		return
	}
	writeJSON(w, http.StatusOK, struct {
		Confirmed bool `json:"confirmed"`
	}{Confirmed: true})
}

func (b *referenceBroker) authorizeDevice(w http.ResponseWriter, r *http.Request) bool {
	expectedAuthorization := sha256.Sum256([]byte("Bearer " + b.token))
	providedAuthorization := sha256.Sum256([]byte(r.Header.Get("Authorization")))
	if subtle.ConstantTimeCompare(providedAuthorization[:], expectedAuthorization[:]) != 1 {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return false
	}
	if r.Header.Get("X-Abundance-Device-Id") == "" {
		http.Error(w, "missing device id", http.StatusBadRequest)
		return false
	}
	return true
}

func (b *referenceBroker) readAnnouncement(sessionID string) (sessionAnnouncement, error) {
	var announcement sessionAnnouncement
	body, err := os.ReadFile(b.announcementPath(sessionID))
	if err != nil {
		return announcement, err
	}
	err = json.Unmarshal(body, &announcement)
	return announcement, err
}

func (b *referenceBroker) artifactMatches(sessionID string, artifact announcedArtifact) (bool, error) {
	if b.s3 != nil {
		return b.s3.artifactMatches(sessionID, artifact)
	}
	file, err := os.Open(b.artifactPath(sessionID, artifact.Name))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return false, err
	}
	return strings.EqualFold(hex.EncodeToString(digest.Sum(nil)), artifact.SHA256), nil
}

func (b *referenceBroker) announcementPath(sessionID string) string {
	return filepath.Join(b.storageDir, sessionID, announcementFilename)
}

func (b *referenceBroker) artifactPath(sessionID, artifactName string) string {
	return filepath.Join(b.storageDir, sessionID, artifactDirectory, artifactName)
}

func flattenArtifacts(announcement sessionAnnouncement) ([]announcedArtifact, error) {
	artifacts := make([]announcedArtifact, 0, len(announcement.Segments)*3+len(announcement.Logs))
	seen := make(map[string]struct{}, cap(artifacts))
	appendArtifact := func(artifact announcedArtifact) error {
		if !safePathName(artifact.Name) || !validSHA256(artifact.SHA256) || artifact.Bytes < 0 {
			return fmt.Errorf("invalid announced artifact %q", artifact.Name)
		}
		if _, exists := seen[artifact.Name]; exists {
			return fmt.Errorf("duplicate announced artifact %q", artifact.Name)
		}
		seen[artifact.Name] = struct{}{}
		artifacts = append(artifacts, artifact)
		return nil
	}
	for _, segment := range announcement.Segments {
		for _, artifact := range []announcedArtifact{segment.Video, segment.IMU, segment.Frames} {
			if err := appendArtifact(artifact); err != nil {
				return nil, err
			}
		}
	}
	for _, artifact := range announcement.Logs {
		if err := appendArtifact(artifact); err != nil {
			return nil, err
		}
	}
	return artifacts, nil
}

func findArtifact(announcement sessionAnnouncement, name string) (announcedArtifact, bool) {
	artifacts, err := flattenArtifacts(announcement)
	if err != nil {
		return announcedArtifact{}, false
	}
	for _, artifact := range artifacts {
		if artifact.Name == name {
			return artifact, true
		}
	}
	return announcedArtifact{}, false
}

func safePathName(name string) bool {
	return name != "" && name != "." && name != ".." && filepath.Base(name) == name && !strings.Contains(name, "\\")
}

func validSHA256(value string) bool {
	if len(value) != sha256.Size*2 {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && len(decoded) == sha256.Size
}

func contentTypeForArtifact(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".ts":
		return "video/mp2t"
	case ".csv":
		return "text/csv"
	case ".json":
		return "application/json"
	default:
		return "application/octet-stream"
	}
}
func publicRequestURL(request *http.Request, requestPath string) string {
	scheme := "http"
	if forwarded := strings.TrimSpace(strings.Split(request.Header.Get("X-Forwarded-Proto"), ",")[0]); forwarded == "http" || forwarded == "https" {
		scheme = forwarded
	}
	return (&url.URL{Scheme: scheme, Host: request.Host, Path: requestPath}).String()
}

func writeFileAtomically(path string, body []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".announcement-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	committed := false
	defer func() {
		temporary.Close()
		if !committed {
			os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(mode); err != nil {
		return err
	}
	if _, err := temporary.Write(body); err != nil {
		return err
	}
	if err := temporary.Sync(); err != nil {
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return err
	}
	committed = true
	return nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func markSession(w http.ResponseWriter, sessionID string) {
	if response, ok := w.(*loggedResponse); ok && sessionID != "" {
		response.session = sessionID
	}
}
