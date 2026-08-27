#!/usr/bin/env bash
# Runs the live DynamoDB smoke test end to end: provision -> test -> teardown.
# Teardown always runs, even if the test fails.
#
# Two identities are involved:
#   PROFILE           - admin-ish profile that creates the table + attaches
#                        the scoped inline policy (default: sts-smoke-test-provisioner)
#   TEST_USER_PROFILE - profile holding sts-smoke-test-user's own static keys;
#                        used only to mint a short-lived session token
#                        (default: sts-smoke-test-user)
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${PROFILE:-sts-smoke-test-provisioner}"
REGION="${REGION:-us-east-1}"
TEST_USER_PROFILE="${TEST_USER_PROFILE:-sts-smoke-test-user}"
TABLE_NAME="${TABLE_NAME:-dynamodb-eio-live-test}"

export PROFILE REGION TABLE_NAME

cleanup() {
  echo "==> Tearing down..."
  ./scripts/teardown.sh
}
trap cleanup EXIT

echo "==> Provisioning..."
./scripts/setup.sh

echo "==> Minting short-lived session token for ${TEST_USER_PROFILE}..."
creds="$(aws sts get-session-token --profile "$TEST_USER_PROFILE" --duration-seconds 900 \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<"$creds"

export DYNAMODB_EIO_LIVE=1
export DYNAMODB_EIO_LIVE_TABLE="$TABLE_NAME"
export AWS_REGION="$REGION"

# ponytail: IAM policy attachment isn't immediately consistent — same gap
# s3-eio's test-e2e.sh works around. Probe with the real permission (put a
# scratch item, then clean it up) using the test user's own credentials
# until it's actually enforced, instead of guessing a fixed sleep.
echo "==> Waiting for IAM policy to propagate..."
probe_item='{"pk":{"S":"sun-live-test#iam-propagation-probe"},"sk":{"S":"item"}}'
attempt=0
delay=2
deadline=$((SECONDS + 300))
until aws dynamodb put-item --table-name "$TABLE_NAME" --item "$probe_item" \
  --region "$REGION" > /dev/null 2>&1
do
  attempt=$((attempt + 1))
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "error: PutItem still denied after ${attempt} attempts / 5m (IAM policy propagation?)" >&2
    exit 1
  fi
  echo "    not yet authorized, retrying in ${delay}s (attempt ${attempt})..."
  sleep "$delay"
  if [ "$delay" -lt 16 ]; then delay=$((delay * 2)); fi
done
aws dynamodb delete-item --table-name "$TABLE_NAME" \
  --key '{"pk":{"S":"sun-live-test#iam-propagation-probe"},"sk":{"S":"item"}}' \
  --region "$REGION" > /dev/null

echo "==> Running live DynamoDB smoke test against table ${TABLE_NAME}..."
dune runtest test/
