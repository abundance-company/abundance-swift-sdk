package broker

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	testAWSAccessKey = "AKIDEXAMPLE"
	testAWSSecretKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
	testAWSRegion    = "us-test-1"
	testAWSToken     = "temporary-session-token"
	testS3Bucket     = "customer-recordings"
	testS3Prefix     = "abundance/incoming"
)

type fakeS3Object struct {
	body     []byte
	checksum string
}

type fakeS3 struct {
	t             *testing.T
	server        *httptest.Server
	objectsMu     sync.Mutex
	objects       map[string]fakeS3Object
	expectedPaths map[string]struct{}
}

func newFakeS3(t *testing.T, expectedPaths []string) *fakeS3 {
	t.Helper()
	fake := &fakeS3{
		t:             t,
		objects:       make(map[string]fakeS3Object),
		expectedPaths: make(map[string]struct{}, len(expectedPaths)),
	}
	for _, expectedPath := range expectedPaths {
		fake.expectedPaths[expectedPath] = struct{}{}
	}
	fake.server = httptest.NewServer(http.HandlerFunc(fake.serveHTTP))
	t.Cleanup(fake.server.Close)
	return fake
}

func (f *fakeS3) serveHTTP(response http.ResponseWriter, request *http.Request) {
	if _, ok := f.expectedPaths[request.URL.Path]; !ok {
		http.Error(response, "unexpected bucket or key", http.StatusBadRequest)
		return
	}
	switch request.Method {
	case http.MethodPut:
		if err := validateTestPresign(request, time.Now().UTC()); err != nil {
			http.Error(response, err.Error(), http.StatusForbidden)
			return
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			http.Error(response, err.Error(), http.StatusBadRequest)
			return
		}
		digest := sha256.Sum256(body)
		checksum := request.Header.Get(checksumHeaderName)
		wantChecksum := checksumBase64ForTest(digest[:])
		if checksum != wantChecksum {
			http.Error(response, "checksum mismatch", http.StatusBadRequest)
			return
		}
		f.objectsMu.Lock()
		f.objects[request.URL.Path] = fakeS3Object{body: append([]byte(nil), body...), checksum: checksum}
		f.objectsMu.Unlock()
		response.WriteHeader(http.StatusOK)
	case http.MethodHead:
		if err := validateTestSignedRequest(request); err != nil {
			http.Error(response, err.Error(), http.StatusForbidden)
			return
		}
		f.objectsMu.Lock()
		object, ok := f.objects[request.URL.Path]
		f.objectsMu.Unlock()
		if !ok {
			http.Error(response, "not found", http.StatusNotFound)
			return
		}
		response.Header().Set("Content-Length", strconv.Itoa(len(object.body)))
		response.Header().Set(checksumHeaderName, object.checksum)
		response.WriteHeader(http.StatusOK)
	default:
		http.Error(response, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func TestReferenceBrokerS3UploadLifecycle(t *testing.T) {
	artifactBodies := map[string][]byte{
		"s000042_k3x9qz_00000.ts":         []byte("video bytes in S3"),
		"s000042_k3x9qz_00000.csv":        []byte("imu bytes in S3"),
		"s000042_k3x9qz_00000_frames.csv": []byte("frame bytes in S3"),
		"clock-model.json":                []byte(`{"clock":"model"}`),
	}
	expectedPaths := make([]string, 0, len(artifactBodies))
	for name := range artifactBodies {
		expectedPaths = append(expectedPaths, "/"+testS3Bucket+"/"+testS3Prefix+"/"+testSession+"/"+name)
	}
	fake := newFakeS3(t, expectedPaths)
	store := newTestS3Store(t, fake.server.URL)
	broker := httptest.NewServer(NewReferenceBrokerWithS3(t.TempDir(), testToken, log.New(io.Discard, "", 0), store))
	t.Cleanup(broker.Close)

	plan := postAnnouncement(t, broker.URL, testAnnouncement(artifactBodies))
	if len(plan.Uploads) != len(artifactBodies) {
		t.Fatalf("announce uploads = %d, want %d", len(plan.Uploads), len(artifactBodies))
	}
	if plan.ExpiresAt <= time.Now().Unix() {
		t.Fatalf("expires_at = %d, want a future time", plan.ExpiresAt)
	}
	for _, destination := range plan.Uploads {
		parsed, err := url.Parse(destination.URL)
		if err != nil {
			t.Fatal(err)
		}
		wantPath := "/" + testS3Bucket + "/" + testS3Prefix + "/" + testSession + "/" + destination.Name
		if parsed.Path != wantPath {
			t.Fatalf("destination path = %q, want %q", parsed.Path, wantPath)
		}
		if parsed.Query().Get("X-Amz-Security-Token") != testAWSToken {
			t.Fatal("presigned URL omitted the AWS session token")
		}
		if destination.Method != http.MethodPut {
			t.Fatalf("destination method = %q, want PUT", destination.Method)
		}
		if destination.Headers[checksumHeaderName] == "" || destination.Headers["Content-Type"] == "" {
			t.Fatalf("destination headers = %v, want checksum and content type", destination.Headers)
		}
	}

	missingResponse := postCompletion(t, plan.CompleteURL, http.StatusConflict)
	assertMissingNames(t, missingResponse, sortedArtifactNames(artifactBodies))

	for _, destination := range plan.Uploads {
		putS3Artifact(t, destination, artifactBodies[destination.Name], http.StatusOK)
	}

	tamperedPath := expectedPaths[0]
	fake.objectsMu.Lock()
	original := fake.objects[tamperedPath]
	fake.objects[tamperedPath] = fakeS3Object{body: original.body, checksum: checksumBase64ForTest(make([]byte, sha256.Size))}
	fake.objectsMu.Unlock()
	checksumResponse := postCompletion(t, plan.CompleteURL, http.StatusConflict)
	assertMissingNames(t, checksumResponse, []string{strings.TrimPrefix(tamperedPath, "/"+testS3Bucket+"/"+testS3Prefix+"/"+testSession+"/")})

	fake.objectsMu.Lock()
	fake.objects[tamperedPath] = fakeS3Object{body: append(append([]byte(nil), original.body...), 'x'), checksum: original.checksum}
	fake.objectsMu.Unlock()
	sizeResponse := postCompletion(t, plan.CompleteURL, http.StatusConflict)
	assertMissingNames(t, sizeResponse, []string{strings.TrimPrefix(tamperedPath, "/"+testS3Bucket+"/"+testS3Prefix+"/"+testSession+"/")})

	fake.objectsMu.Lock()
	fake.objects[tamperedPath] = original
	fake.objectsMu.Unlock()
	completeResponse := postCompletion(t, plan.CompleteURL, http.StatusOK)
	var confirmation struct {
		Confirmed bool `json:"confirmed"`
	}
	decodeJSON(t, completeResponse, &confirmation)
	if !confirmation.Confirmed {
		t.Fatal("completion was not confirmed")
	}

	reannounced := postAnnouncement(t, broker.URL, testAnnouncement(artifactBodies))
	if len(reannounced.Uploads) != 0 {
		t.Fatalf("re-announce uploads = %v, want none", reannounced.Uploads)
	}
}

func TestS3PresignRejectsExpiredURL(t *testing.T) {
	artifact := announcedArtifact{Name: "clock-model.json", Bytes: 2, SHA256: hashBytes([]byte("{}"))}
	expectedPath := "/" + testS3Bucket + "/" + testS3Prefix + "/" + testSession + "/" + artifact.Name
	fake := newFakeS3(t, []string{expectedPath})
	store := newTestS3Store(t, fake.server.URL)
	destination, err := store.destination(testSession, artifact, time.Now().UTC().Add(-presignLifetime-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	putS3Artifact(t, destination, []byte("{}"), http.StatusForbidden)
}

func TestS3PresignUsesAWSPathEncoding(t *testing.T) {
	body := []byte(`{"clock":"model"}`)
	artifact := announcedArtifact{
		Name:   "clock+model=station.json",
		Bytes:  int64(len(body)),
		SHA256: hashBytes(body),
	}
	expectedPath := "/" + testS3Bucket + "/" + testS3Prefix + "/" + testSession + "/" + artifact.Name
	fake := newFakeS3(t, []string{expectedPath})
	store := newTestS3Store(t, fake.server.URL)
	destination, err := store.destination(testSession, artifact, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := url.Parse(destination.URL)
	if err != nil {
		t.Fatal(err)
	}
	wantEscapedPath := "/" + testS3Bucket + "/" + testS3Prefix + "/" + testSession + "/clock%2Bmodel%3Dstation.json"
	if parsed.EscapedPath() != wantEscapedPath {
		t.Fatalf("escaped destination path = %q, want %q", parsed.EscapedPath(), wantEscapedPath)
	}
	putS3Artifact(t, destination, body, http.StatusOK)
	matches, err := store.artifactMatches(testSession, artifact)
	if err != nil {
		t.Fatal(err)
	}
	if !matches {
		t.Fatal("uploaded artifact did not match")
	}
}

func TestPublicRequestURLUsesForwardedTLS(t *testing.T) {
	request := httptest.NewRequest(http.MethodPost, "http://internal:8080/sessions", nil)
	request.Host = "customer-broker.fly.dev"
	request.Header.Set("X-Forwarded-Proto", "https")
	got := publicRequestURL(request, "/sessions/session-1/complete")
	want := "https://customer-broker.fly.dev/sessions/session-1/complete"
	if got != want {
		t.Fatalf("public request URL = %q, want %q", got, want)
	}
}

func newTestS3Store(t *testing.T, endpoint string) *S3Store {
	t.Helper()
	store, err := NewS3Store(S3Configuration{
		Bucket:          testS3Bucket,
		Region:          testAWSRegion,
		Endpoint:        endpoint,
		Prefix:          testS3Prefix,
		AccessKeyID:     testAWSAccessKey,
		SecretAccessKey: testAWSSecretKey,
		SessionToken:    testAWSToken,
	})
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func putS3Artifact(t *testing.T, destination artifactDestination, body []byte, wantStatus int) {
	t.Helper()
	request, err := http.NewRequest(destination.Method, destination.URL, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	for name, value := range destination.Headers {
		request.Header.Set(name, value)
	}
	request.Header.Set("X-Abundance-SHA256", hashBytes(body))
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != wantStatus {
		responseBody, _ := io.ReadAll(response.Body)
		t.Fatalf("S3 PUT status = %d, want %d: %s", response.StatusCode, wantStatus, responseBody)
	}
}

func assertMissingNames(t *testing.T, response *http.Response, want []string) {
	t.Helper()
	var body struct {
		Missing []string `json:"missing"`
	}
	decodeJSON(t, response, &body)
	sort.Strings(body.Missing)
	sort.Strings(want)
	if !equalStrings(body.Missing, want) {
		t.Fatalf("missing = %v, want %v", body.Missing, want)
	}
}

func sortedArtifactNames(artifacts map[string][]byte) []string {
	names := make([]string, 0, len(artifacts))
	for name := range artifacts {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func validateTestPresign(request *http.Request, now time.Time) error {
	query := request.URL.Query()
	if query.Get("X-Amz-Algorithm") != awsAlgorithm {
		return fmt.Errorf("algorithm = %q", query.Get("X-Amz-Algorithm"))
	}
	signedAt, err := time.Parse("20060102T150405Z", query.Get("X-Amz-Date"))
	if err != nil {
		return fmt.Errorf("parse signing time: %w", err)
	}
	expiresSeconds, err := strconv.ParseInt(query.Get("X-Amz-Expires"), 10, 64)
	if err != nil || expiresSeconds <= 0 || expiresSeconds > 7*24*60*60 {
		return fmt.Errorf("invalid expiry %q", query.Get("X-Amz-Expires"))
	}
	if now.Before(signedAt.Add(-5*time.Minute)) || now.After(signedAt.Add(time.Duration(expiresSeconds)*time.Second)) {
		return fmt.Errorf("presigned URL expired or not yet valid")
	}
	if query.Get("X-Amz-Security-Token") != testAWSToken {
		return fmt.Errorf("session token mismatch")
	}
	credentialParts := strings.Split(query.Get("X-Amz-Credential"), "/")
	if len(credentialParts) != 5 || credentialParts[0] != testAWSAccessKey || credentialParts[1] != signedAt.Format("20060102") || credentialParts[2] != testAWSRegion || credentialParts[3] != "s3" || credentialParts[4] != awsRequestType {
		return fmt.Errorf("credential scope = %q", query.Get("X-Amz-Credential"))
	}
	signedHeaders := strings.Split(query.Get("X-Amz-SignedHeaders"), ";")
	if strings.Join(signedHeaders, ";") != "content-type;host;x-amz-checksum-sha256" {
		return fmt.Errorf("signed headers = %q", signedHeaders)
	}
	providedSignature := query.Get("X-Amz-Signature")
	query.Del("X-Amz-Signature")
	canonical := reconstructCanonicalRequest(request, query.Encode(), signedHeaders, unsignedPayload)
	scope := strings.Join(credentialParts[1:], "/")
	wantSignature := calculateTestSignature(testAWSSecretKey, signedAt, testAWSRegion, scope, canonical)
	if !hmac.Equal([]byte(providedSignature), []byte(wantSignature)) {
		return fmt.Errorf("signature mismatch")
	}
	return nil
}

func validateTestSignedRequest(request *http.Request) error {
	authorization := request.Header.Get("Authorization")
	if !strings.HasPrefix(authorization, awsAlgorithm+" ") {
		return fmt.Errorf("missing SigV4 authorization")
	}
	attributes := make(map[string]string)
	for _, item := range strings.Split(strings.TrimPrefix(authorization, awsAlgorithm+" "), ",") {
		parts := strings.SplitN(strings.TrimSpace(item), "=", 2)
		if len(parts) != 2 {
			return fmt.Errorf("invalid authorization attribute")
		}
		attributes[parts[0]] = parts[1]
	}
	credentialParts := strings.Split(attributes["Credential"], "/")
	if len(credentialParts) != 5 || credentialParts[0] != testAWSAccessKey || credentialParts[2] != testAWSRegion || credentialParts[3] != "s3" || credentialParts[4] != awsRequestType {
		return fmt.Errorf("credential scope = %q", attributes["Credential"])
	}
	signedAt, err := time.Parse("20060102T150405Z", request.Header.Get("X-Amz-Date"))
	if err != nil {
		return err
	}
	if credentialParts[1] != signedAt.Format("20060102") || request.Header.Get("X-Amz-Security-Token") != testAWSToken {
		return fmt.Errorf("signed request credential mismatch")
	}
	if request.Header.Get("X-Amz-Checksum-Mode") != "ENABLED" {
		return fmt.Errorf("checksum mode was not enabled")
	}
	signedHeaders := strings.Split(attributes["SignedHeaders"], ";")
	canonical := reconstructCanonicalRequest(request, request.URL.Query().Encode(), signedHeaders, request.Header.Get("X-Amz-Content-Sha256"))
	scope := strings.Join(credentialParts[1:], "/")
	wantSignature := calculateTestSignature(testAWSSecretKey, signedAt, testAWSRegion, scope, canonical)
	if !hmac.Equal([]byte(attributes["Signature"]), []byte(wantSignature)) {
		return fmt.Errorf("signed request signature mismatch")
	}
	return nil
}

func reconstructCanonicalRequest(request *http.Request, canonicalQuery string, signedHeaders []string, payloadHash string) string {
	var canonicalHeaders strings.Builder
	for _, name := range signedHeaders {
		value := request.Header.Get(name)
		if name == "host" {
			value = request.Host
		}
		canonicalHeaders.WriteString(name)
		canonicalHeaders.WriteByte(':')
		canonicalHeaders.WriteString(strings.Join(strings.Fields(value), " "))
		canonicalHeaders.WriteByte('\n')
	}
	return strings.Join([]string{
		request.Method,
		awsPathEncode(request.URL.Path),
		canonicalQuery,
		canonicalHeaders.String(),
		strings.Join(signedHeaders, ";"),
		payloadHash,
	}, "\n")
}

func calculateTestSignature(secret string, signedAt time.Time, region, scope, canonical string) string {
	digest := sha256.Sum256([]byte(canonical))
	stringToSign := strings.Join([]string{awsAlgorithm, signedAt.Format("20060102T150405Z"), scope, hex.EncodeToString(digest[:])}, "\n")
	dateKey := testHMAC([]byte("AWS4"+secret), signedAt.Format("20060102"))
	regionKey := testHMAC(dateKey, region)
	serviceKey := testHMAC(regionKey, "s3")
	signingKey := testHMAC(serviceKey, awsRequestType)
	return hex.EncodeToString(testHMAC(signingKey, stringToSign))
}

func testHMAC(key []byte, value string) []byte {
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(value))
	return mac.Sum(nil)
}

func checksumBase64ForTest(digest []byte) string {
	return base64.StdEncoding.EncodeToString(digest)
}
