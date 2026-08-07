# Fly.io TLS + S3 deployment

Fly terminates public TLS and forwards plain HTTP to the broker on port 8080. The broker honors `X-Forwarded-Proto`, so the device receives an HTTPS `complete_url`. S3 upload URLs are presigned with a stdlib-only AWS SigV4 implementation; no AWS SDK is linked.

Each presigned PUT requires the announced SHA-256 as `X-Amz-Checksum-Sha256`. S3 rejects bytes that do not match that checksum and stores it as object metadata. Completion therefore uses a signed `HEAD` and compares both `Content-Length` and the stored `X-Amz-Checksum-Sha256`; it does not download multi-gigabyte objects to hash them again. The IAM identity needs `s3:PutObject` and `s3:GetObject` on the configured prefix. It also needs `s3:ListBucket` on this dedicated bucket so S3 answers a HEAD for an absent key with 404 (without that permission S3 deliberately answers 403).

## Create the bucket and least-privilege credentials

Run from a Bash shell with an administrator AWS profile. Choose globally unique values first:

```bash
export AWS_REGION=us-east-1
export BUCKET=replace-with-a-globally-unique-bucket
export PREFIX=station
export IAM_USER=abundance-broker-ref

aws s3 mb "s3://${BUCKET}" --region "$AWS_REGION"
aws iam create-user --user-name "$IAM_USER"
cat >/tmp/abundance-broker-s3-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::${BUCKET}/${PREFIX}/*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${BUCKET}"
    }
  ]
}
EOF
aws iam put-user-policy \
  --user-name "$IAM_USER" \
  --policy-name abundance-broker-s3 \
  --policy-document file:///tmp/abundance-broker-s3-policy.json
read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY <<<"$(aws iam create-access-key \
  --user-name "$IAM_USER" \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' \
  --output text)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```

For temporary AWS credentials, also set `AWS_SESSION_TOKEN`; the broker includes it in presigned URLs and signed HEAD requests.

## Fill in broker.env

All broker configuration is environment variables — no flags. `broker.env.example`
beside this README documents every one; copy it to `broker.env` (gitignored,
`chmod 600`) and fill in the token, bucket, region, prefix, and the IAM key
from the step above. That one file then drives the local broker, the bench
script, and the Fly deployment below.

```bash
cp deploy/broker.env.example deploy/broker.env
chmod 600 deploy/broker.env
"${EDITOR:-vi}" deploy/broker.env
```

Run locally with the file sourced:

```bash
set -a; . deploy/broker.env; set +a
go run ./cmd/abundance-broker-ref
```

## Create and deploy the Fly app

Run from this directory (reference-broker/). `broker_data` persists announcements between announce and complete; artifact bytes live only in S3.

```bash
export FLY_APP=replace-with-a-globally-unique-fly-app
export FLY_REGION=iad

flyctl auth login
flyctl apps create "$FLY_APP"
flyctl volumes create broker_data --app "$FLY_APP" --region "$FLY_REGION" --size 1 --yes
flyctl secrets import --app "$FLY_APP" < deploy/broker.env
flyctl deploy . \
  --app "$FLY_APP" \
  --config deploy/fly.toml \
  --dockerfile deploy/Dockerfile
test "$(curl --silent --output /dev/null --write-out '%{http_code}' "https://${FLY_APP}.fly.dev/does-not-exist")" = 404
```

The file holds only the token and the object-store backend; listen address
and storage directory come from fly.toml's `[env]` on Fly and from the
binary's defaults (`:8080`, `./broker-data`) locally.

The final curl is expected to receive an HTTP error from the live broker; it proves DNS and managed TLS are active. Confirm the certificate explicitly with:

```bash
curl --verbose "https://${FLY_APP}.fly.dev/does-not-exist" --output /dev/null 2>&1 | tee /tmp/abundance-fly-tls.txt
```

To use MinIO or LocalStack instead, set `ABUNDANCE_S3_ENDPOINT=http://host:port` in `broker.env` and supply that service's access key and secret through the same standard AWS variables.

## Bench HTTPS run

Flash firmware 1.1.0 by SD card first; these commands never deploy firmware. Connect to the device SoftAP, export its existing bearer token, and join the configured test router before enabling Station upload:

```bash
export DEVICE_URL=http://192.168.42.1:8443
export DEVICE_TOKEN=replace-with-paired-device-token
export FLY_APP=replace-with-your-app
# BROKER_TOKEN / BUCKET / PREFIX come from broker.env:
set -a; . deploy/broker.env; set +a
export BROKER_TOKEN="$ABUNDANCE_BROKER_TOKEN" BUCKET="$ABUNDANCE_S3_BUCKET" PREFIX="$ABUNDANCE_S3_PREFIX"
export ROUTER_SSID=your-wifi-network
export ROUTER_PSK=your-wifi-password

curl --fail --silent --show-error \
  -H "Authorization: Bearer ${DEVICE_TOKEN}" \
  -H 'Content-Type: application/json' \
  --data "$(jq -n --arg ssid "$ROUTER_SSID" --arg psk "$ROUTER_PSK" '{ssid:$ssid,psk:$psk}')" \
  "${DEVICE_URL}/v1/wifi"
curl --fail --silent --show-error \
  -H "Authorization: Bearer ${DEVICE_TOKEN}" \
  "${DEVICE_URL}/v1/wifi"
curl --fail --silent --show-error -X PUT \
  -H "Authorization: Bearer ${DEVICE_TOKEN}" \
  -H 'Content-Type: application/json' \
  --data "{\"enabled\":true,\"base_url\":\"https://${FLY_APP}.fly.dev\",\"token\":\"${BROKER_TOKEN}\"}" \
  "${DEVICE_URL}/v1/upload"
```

The PUT must report `"reachable":true`. If there is no published session, record a short one, then stop it:

```bash
curl --fail --silent --show-error -X POST -H "Authorization: Bearer ${DEVICE_TOKEN}" "${DEVICE_URL}/v1/recording/start"
sleep 15
curl --fail --silent --show-error -X POST -H "Authorization: Bearer ${DEVICE_TOKEN}" "${DEVICE_URL}/v1/recording/stop"
```

Poll until the uploader returns to `idle` with no pending sessions, save the transcript, and inspect the resulting objects and checksums:

```bash
while :; do
  STATUS="$(curl --fail --silent --show-error -H "Authorization: Bearer ${DEVICE_TOKEN}" "${DEVICE_URL}/v1/upload")" || exit
  printf '%s\n' "$STATUS" | tee -a /tmp/abundance-s3-bench.txt
  if jq -e '.state == "idle" and .pending_sessions == 0' >/dev/null <<<"$STATUS"; then
    break
  fi
  sleep 2
done
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "${PREFIX}/" --output table | tee -a /tmp/abundance-s3-bench.txt
for KEY in $(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "${PREFIX}/" --query 'Contents[].Key' --output text); do
  printf 'key=%s\n' "$KEY"
  aws s3api head-object --bucket "$BUCKET" --key "$KEY" --checksum-mode ENABLED \
    --query '{size:ContentLength,sha256:ChecksumSHA256}' --output json
done | tee -a /tmp/abundance-s3-bench.txt
curl --fail --silent --show-error -H "Authorization: Bearer ${DEVICE_TOKEN}" "${DEVICE_URL}/v1/recordings" | tee -a /tmp/abundance-s3-bench.txt
```

Record the Fly URL, S3 bucket/prefix, `/tmp/abundance-fly-tls.txt`, and `/tmp/abundance-s3-bench.txt` in ticket 09. The uploaded session must be absent from `/v1/recordings`; every S3 object must have a non-empty `ChecksumSHA256` and the expected byte size.
