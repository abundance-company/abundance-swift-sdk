package broker

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	awsAlgorithm       = "AWS4-HMAC-SHA256"
	awsRequestType     = "aws4_request"
	unsignedPayload    = "UNSIGNED-PAYLOAD"
	presignLifetime    = time.Hour
	maximumErrorBody   = 4096
	checksumHeaderName = "X-Amz-Checksum-Sha256"
)

type S3Configuration struct {
	Bucket          string
	Region          string
	Endpoint        string
	Prefix          string
	AccessKeyID     string
	SecretAccessKey string
	SessionToken    string
}

type S3Store struct {
	bucket          string
	region          string
	endpoint        *url.URL
	prefix          string
	accessKeyID     string
	secretAccessKey string
	sessionToken    string
	client          *http.Client
}

func NewS3Store(configuration S3Configuration) (*S3Store, error) {
	if configuration.Bucket == "" || strings.ContainsAny(configuration.Bucket, "/\\") {
		return nil, errors.New("S3 bucket must be a non-empty bucket name")
	}
	if configuration.Region == "" {
		return nil, errors.New("S3 region is required")
	}
	if configuration.AccessKeyID == "" || configuration.SecretAccessKey == "" {
		return nil, errors.New("AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required in S3 mode")
	}
	endpointValue := configuration.Endpoint
	if endpointValue == "" {
		endpointValue = "https://s3." + configuration.Region + ".amazonaws.com"
	}
	endpoint, err := url.Parse(endpointValue)
	if err != nil {
		return nil, fmt.Errorf("parse S3 endpoint: %w", err)
	}
	if (endpoint.Scheme != "http" && endpoint.Scheme != "https") || endpoint.Host == "" || endpoint.User != nil || endpoint.RawQuery != "" || endpoint.Fragment != "" {
		return nil, errors.New("S3 endpoint must be an http(s) URL without credentials, query, or fragment")
	}
	return &S3Store{
		bucket:          configuration.Bucket,
		region:          configuration.Region,
		endpoint:        endpoint,
		prefix:          strings.Trim(configuration.Prefix, "/"),
		accessKeyID:     configuration.AccessKeyID,
		secretAccessKey: configuration.SecretAccessKey,
		sessionToken:    configuration.SessionToken,
		client:          &http.Client{Timeout: 30 * time.Second},
	}, nil
}

func (s *S3Store) destination(sessionID string, artifact announcedArtifact, issuedAt time.Time) (artifactDestination, error) {
	checksum, err := checksumBase64(artifact.SHA256)
	if err != nil {
		return artifactDestination{}, err
	}
	headers := map[string]string{
		"Content-Type":     contentTypeForArtifact(artifact.Name),
		checksumHeaderName: checksum,
	}
	objectURL := s.objectURL(sessionID, artifact.Name)
	presignedURL, err := s.presign(http.MethodPut, objectURL, headers, issuedAt, presignLifetime)
	if err != nil {
		return artifactDestination{}, err
	}
	return artifactDestination{
		Name:    artifact.Name,
		Method:  http.MethodPut,
		URL:     presignedURL,
		Headers: headers,
	}, nil
}

func (s *S3Store) artifactMatches(sessionID string, artifact announcedArtifact) (bool, error) {
	request, err := http.NewRequest(http.MethodHead, s.objectURL(sessionID, artifact.Name).String(), nil)
	if err != nil {
		return false, err
	}
	request.Header.Set("X-Amz-Checksum-Mode", "ENABLED")
	s.sign(request, time.Now().UTC())
	response, err := s.client.Do(request)
	if err != nil {
		return false, fmt.Errorf("HEAD S3 object: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotFound {
		return false, nil
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(response.Body, maximumErrorBody))
		return false, fmt.Errorf("HEAD S3 object returned %s: %s", response.Status, strings.TrimSpace(string(body)))
	}
	checksum, err := checksumBase64(artifact.SHA256)
	if err != nil {
		return false, err
	}
	return response.ContentLength == artifact.Bytes && response.Header.Get(checksumHeaderName) == checksum, nil
}

func (s *S3Store) objectURL(sessionID, artifactName string) *url.URL {
	objectURL := *s.endpoint
	components := []string{objectURL.Path, s.bucket}
	if s.prefix != "" {
		components = append(components, s.prefix)
	}
	components = append(components, sessionID, artifactName)
	objectURL.Path = path.Join(components...)
	if !strings.HasPrefix(objectURL.Path, "/") {
		objectURL.Path = "/" + objectURL.Path
	}
	objectURL.RawPath = awsPathEncode(objectURL.Path)
	return &objectURL
}

func (s *S3Store) presign(method string, target *url.URL, headers map[string]string, issuedAt time.Time, lifetime time.Duration) (string, error) {
	if lifetime <= 0 || lifetime > 7*24*time.Hour || lifetime%time.Second != 0 {
		return "", errors.New("invalid SigV4 presign lifetime")
	}
	issuedAt = issuedAt.UTC()
	date := issuedAt.Format("20060102")
	scope := strings.Join([]string{date, s.region, "s3", awsRequestType}, "/")
	signedHeaders := make([]string, 0, len(headers)+1)
	canonicalValues := make(map[string]string, len(headers)+1)
	canonicalValues["host"] = target.Host
	for name, value := range headers {
		lowerName := strings.ToLower(name)
		signedHeaders = append(signedHeaders, lowerName)
		canonicalValues[lowerName] = value
	}
	signedHeaders = append(signedHeaders, "host")
	sort.Strings(signedHeaders)
	signedHeaderNames := strings.Join(signedHeaders, ";")

	presigned := *target
	presigned.RawPath = awsPathEncode(presigned.Path)
	query := presigned.Query()
	query.Set("X-Amz-Algorithm", awsAlgorithm)
	query.Set("X-Amz-Credential", s.accessKeyID+"/"+scope)
	query.Set("X-Amz-Date", issuedAt.Format("20060102T150405Z"))
	query.Set("X-Amz-Expires", strconv.FormatInt(int64(lifetime/time.Second), 10))
	query.Set("X-Amz-SignedHeaders", signedHeaderNames)
	if s.sessionToken != "" {
		query.Set("X-Amz-Security-Token", s.sessionToken)
	}
	presigned.RawQuery = query.Encode()
	canonicalRequest := canonicalRequest(method, &presigned, canonicalValues, signedHeaders, unsignedPayload)
	signature := s.signature(scope, issuedAt, canonicalRequest)
	query = presigned.Query()
	query.Set("X-Amz-Signature", signature)
	presigned.RawQuery = query.Encode()
	return presigned.String(), nil
}

func (s *S3Store) sign(request *http.Request, signedAt time.Time) {
	request.URL.RawPath = awsPathEncode(request.URL.Path)
	signedAt = signedAt.UTC()
	emptyDigest := sha256.Sum256(nil)
	payloadHash := hex.EncodeToString(emptyDigest[:])
	request.Header.Set("X-Amz-Content-Sha256", payloadHash)
	request.Header.Set("X-Amz-Date", signedAt.Format("20060102T150405Z"))
	if s.sessionToken != "" {
		request.Header.Set("X-Amz-Security-Token", s.sessionToken)
	}
	signedHeaders := []string{"host", "x-amz-content-sha256", "x-amz-date"}
	canonicalValues := map[string]string{
		"host":                 request.URL.Host,
		"x-amz-content-sha256": payloadHash,
		"x-amz-date":           request.Header.Get("X-Amz-Date"),
	}
	if checksumMode := request.Header.Get("X-Amz-Checksum-Mode"); checksumMode != "" {
		signedHeaders = append(signedHeaders, "x-amz-checksum-mode")
		canonicalValues["x-amz-checksum-mode"] = checksumMode
		sort.Strings(signedHeaders)
	}
	if s.sessionToken != "" {
		signedHeaders = append(signedHeaders, "x-amz-security-token")
		canonicalValues["x-amz-security-token"] = s.sessionToken
	}
	date := signedAt.Format("20060102")
	scope := strings.Join([]string{date, s.region, "s3", awsRequestType}, "/")
	canonical := canonicalRequest(request.Method, request.URL, canonicalValues, signedHeaders, payloadHash)
	signature := s.signature(scope, signedAt, canonical)
	request.Header.Set("Authorization", fmt.Sprintf("%s Credential=%s/%s, SignedHeaders=%s, Signature=%s", awsAlgorithm, s.accessKeyID, scope, strings.Join(signedHeaders, ";"), signature))
}

func (s *S3Store) signature(scope string, signedAt time.Time, canonical string) string {
	canonicalDigest := sha256.Sum256([]byte(canonical))
	stringToSign := strings.Join([]string{
		awsAlgorithm,
		signedAt.Format("20060102T150405Z"),
		scope,
		hex.EncodeToString(canonicalDigest[:]),
	}, "\n")
	dateKey := hmacSHA256([]byte("AWS4"+s.secretAccessKey), signedAt.Format("20060102"))
	regionKey := hmacSHA256(dateKey, s.region)
	serviceKey := hmacSHA256(regionKey, "s3")
	signingKey := hmacSHA256(serviceKey, awsRequestType)
	return hex.EncodeToString(hmacSHA256(signingKey, stringToSign))
}

func canonicalRequest(method string, target *url.URL, headerValues map[string]string, signedHeaders []string, payloadHash string) string {
	var headers strings.Builder
	for _, name := range signedHeaders {
		headers.WriteString(name)
		headers.WriteByte(':')
		headers.WriteString(normalizeHeaderValue(headerValues[name]))
		headers.WriteByte('\n')
	}
	return strings.Join([]string{
		method,
		awsPathEncode(target.Path),
		target.Query().Encode(),
		headers.String(),
		strings.Join(signedHeaders, ";"),
		payloadHash,
	}, "\n")
}

func awsPathEncode(value string) string {
	const hexadecimal = "0123456789ABCDEF"
	var encoded strings.Builder
	encoded.Grow(len(value))
	for index := range len(value) {
		character := value[index]
		if character == '/' ||
			character >= 'A' && character <= 'Z' ||
			character >= 'a' && character <= 'z' ||
			character >= '0' && character <= '9' ||
			character == '-' || character == '.' || character == '_' || character == '~' {
			encoded.WriteByte(character)
			continue
		}
		encoded.WriteByte('%')
		encoded.WriteByte(hexadecimal[character>>4])
		encoded.WriteByte(hexadecimal[character&0x0f])
	}
	return encoded.String()
}

func normalizeHeaderValue(value string) string {
	return strings.Join(strings.Fields(value), " ")
}

func hmacSHA256(key []byte, value string) []byte {
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte(value))
	return mac.Sum(nil)
}

func checksumBase64(hexDigest string) (string, error) {
	digest, err := hex.DecodeString(hexDigest)
	if err != nil || len(digest) != sha256.Size {
		return "", errors.New("invalid SHA-256 digest")
	}
	return base64.StdEncoding.EncodeToString(digest), nil
}
