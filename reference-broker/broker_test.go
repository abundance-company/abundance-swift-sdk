package broker

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"testing"
)

const (
	testToken    = "bench-token"
	testDeviceID = "261ed43d-c3b9-4664-94b0-b238534b9020"
	testSession  = "s000042_k3x9qz"
)

func TestReferenceBrokerUploadLifecycle(t *testing.T) {
	artifactBodies := map[string][]byte{
		"s000042_k3x9qz_00000.ts":         []byte("video bytes"),
		"s000042_k3x9qz_00000.csv":        []byte("imu bytes"),
		"s000042_k3x9qz_00000_frames.csv": []byte("frame bytes"),
		"clock-model.json":                []byte(`{"clock":"model"}`),
	}
	announcement := testAnnouncement(artifactBodies)
	storageDir := t.TempDir()
	server := httptest.NewServer(NewReferenceBroker(storageDir, testToken, log.New(io.Discard, "", 0)))
	t.Cleanup(server.Close)

	plan := postAnnouncement(t, server.URL, announcement)
	if len(plan.Uploads) != len(artifactBodies) {
		t.Fatalf("announce uploads = %d, want %d", len(plan.Uploads), len(artifactBodies))
	}
	if plan.CompleteURL != server.URL+"/sessions/"+testSession+"/complete" {
		t.Fatalf("complete_url = %q", plan.CompleteURL)
	}
	if plan.ExpiresAt == 0 {
		t.Fatal("expires_at is zero")
	}

	missingResponse := postCompletion(t, plan.CompleteURL, http.StatusConflict)
	var missing struct {
		Missing []string `json:"missing"`
	}
	decodeJSON(t, missingResponse, &missing)
	gotMissing := append([]string(nil), missing.Missing...)
	sort.Strings(gotMissing)
	wantMissing := make([]string, 0, len(artifactBodies))
	for name := range artifactBodies {
		wantMissing = append(wantMissing, name)
	}
	sort.Strings(wantMissing)
	if !equalStrings(gotMissing, wantMissing) {
		t.Fatalf("missing = %v, want %v", gotMissing, wantMissing)
	}

	first := plan.Uploads[0]
	mismatch := putArtifact(t, first.URL, []byte("corrupted"), hashBytes(artifactBodies[first.Name]))
	if mismatch.StatusCode != http.StatusBadRequest {
		body, _ := io.ReadAll(mismatch.Body)
		mismatch.Body.Close()
		t.Fatalf("mismatched PUT status = %d, want 400: %s", mismatch.StatusCode, body)
	}
	mismatch.Body.Close()
	if _, err := os.Stat(filepath.Join(storageDir, testSession, artifactDirectory, first.Name)); !os.IsNotExist(err) {
		t.Fatalf("mismatched artifact was retained: %v", err)
	}

	firstResponse := putArtifact(t, first.URL, artifactBodies[first.Name], hashBytes(artifactBodies[first.Name]))
	if firstResponse.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(firstResponse.Body)
		firstResponse.Body.Close()
		t.Fatalf("PUT %s status = %d, want 200: %s", first.Name, firstResponse.StatusCode, body)
	}
	firstResponse.Body.Close()

	partialPlan := postAnnouncement(t, server.URL, announcement)
	if len(partialPlan.Uploads) != len(artifactBodies)-1 {
		t.Fatalf("partial re-announce uploads = %d, want %d", len(partialPlan.Uploads), len(artifactBodies)-1)
	}
	for _, destination := range partialPlan.Uploads {
		if destination.Name == first.Name {
			t.Fatalf("partial re-announce included held artifact %q", first.Name)
		}
		if destination.Method != http.MethodPut {
			t.Fatalf("method for %s = %q", destination.Name, destination.Method)
		}
		response := putArtifact(t, destination.URL, artifactBodies[destination.Name], hashBytes(artifactBodies[destination.Name]))
		if response.StatusCode != http.StatusOK {
			body, _ := io.ReadAll(response.Body)
			response.Body.Close()
			t.Fatalf("PUT %s status = %d, want 200: %s", destination.Name, response.StatusCode, body)
		}
		response.Body.Close()
	}

	completeResponse := postCompletion(t, plan.CompleteURL, http.StatusOK)
	var complete struct {
		Confirmed bool `json:"confirmed"`
	}
	decodeJSON(t, completeResponse, &complete)
	if !complete.Confirmed {
		t.Fatal("completion was not confirmed")
	}

	reannounced := postAnnouncement(t, server.URL, announcement)
	if len(reannounced.Uploads) != 0 {
		t.Fatalf("re-announce uploads = %v, want none", reannounced.Uploads)
	}
	storedAnnouncement, err := os.ReadFile(filepath.Join(storageDir, testSession, announcementFilename))
	if err != nil {
		t.Fatal(err)
	}
	if !json.Valid(storedAnnouncement) {
		t.Fatal("stored announcement is not JSON")
	}
}

func testAnnouncement(bodies map[string][]byte) []byte {
	sha := func(name string) string { return hashBytes(bodies[name]) }
	announcement := map[string]any{
		"session_id":                      testSession,
		"device_id":                       testDeviceID,
		"firmware_version":                "1.1.0",
		"utc_accuracy_ns":                 2213000,
		"absolute_uvc_latency_calibrated": true,
		"imu_time_offset_ns":              -5400000,
		"video_bitrate_mbps":              16,
		"recovered":                       false,
		"dropped_segment_indices":         []int{},
		"segments": []any{
			map[string]any{
				"index":  0,
				"video":  map[string]any{"name": "s000042_k3x9qz_00000.ts", "bytes": len(bodies["s000042_k3x9qz_00000.ts"]), "sha256": sha("s000042_k3x9qz_00000.ts")},
				"imu":    map[string]any{"name": "s000042_k3x9qz_00000.csv", "bytes": len(bodies["s000042_k3x9qz_00000.csv"]), "sha256": sha("s000042_k3x9qz_00000.csv")},
				"frames": map[string]any{"name": "s000042_k3x9qz_00000_frames.csv", "bytes": len(bodies["s000042_k3x9qz_00000_frames.csv"]), "sha256": sha("s000042_k3x9qz_00000_frames.csv")},
			},
		},
		"logs": []any{
			map[string]any{"name": "clock-model.json", "bytes": len(bodies["clock-model.json"]), "sha256": sha("clock-model.json")},
		},
	}
	body, err := json.Marshal(announcement)
	if err != nil {
		panic(err)
	}
	return body
}

func postAnnouncement(t *testing.T, serverURL string, announcement []byte) uploadPlan {
	t.Helper()
	request, err := http.NewRequest(http.MethodPost, serverURL+"/sessions", bytes.NewReader(announcement))
	if err != nil {
		t.Fatal(err)
	}
	setBrokerHeaders(request)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(response.Body)
		response.Body.Close()
		t.Fatalf("announce status = %d, want 200: %s", response.StatusCode, body)
	}
	var plan uploadPlan
	decodeJSON(t, response, &plan)
	return plan
}

func putArtifact(t *testing.T, destination string, body []byte, sha string) *http.Response {
	t.Helper()
	request, err := http.NewRequest(http.MethodPut, destination, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	setBrokerHeaders(request)
	request.Header.Set("X-Abundance-SHA256", sha)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func postCompletion(t *testing.T, completeURL string, wantStatus int) *http.Response {
	t.Helper()
	report := completionReport{SessionID: testSession}
	body, err := json.Marshal(report)
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodPost, completeURL, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	setBrokerHeaders(request)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != wantStatus {
		responseBody, _ := io.ReadAll(response.Body)
		response.Body.Close()
		t.Fatalf("complete status = %d, want %d: %s", response.StatusCode, wantStatus, responseBody)
	}
	return response
}

func setBrokerHeaders(request *http.Request) {
	request.Header.Set("Authorization", "Bearer "+testToken)
	request.Header.Set("X-Abundance-Device-Id", testDeviceID)
}

func decodeJSON(t *testing.T, response *http.Response, destination any) {
	t.Helper()
	defer response.Body.Close()
	if err := json.NewDecoder(response.Body).Decode(destination); err != nil {
		t.Fatal(err)
	}
}

func hashBytes(body []byte) string {
	digest := sha256.Sum256(body)
	return hex.EncodeToString(digest[:])
}

func equalStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
