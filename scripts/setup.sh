#!/usr/bin/env bash
# Provisions a live-test DynamoDB table in YOUR OWN AWS account and attaches
# a scoped inline policy to an IAM user of your choice, so you can run
# test/test_dynamodb_live.ml (DYNAMODB_EIO_LIVE=1) against a real table.
# Meant for anyone trying this package out locally, not tied to any specific
# account.
#
# Run with an AWS CLI profile that can create/manage the table and put an
# inline policy on the target user (see terraform/main.tf's header for the
# shape of that permission set) — override via env vars:
#   PROFILE=my-admin-profile USER_NAME=my-test-user ./scripts/setup.sh
#
# Not idempotent — re-running against an already-existing table will fail;
# run teardown.sh first if you need to recreate it.
set -euo pipefail

PROFILE="${PROFILE:-sts-smoke-test-provisioner}"
REGION="${REGION:-us-east-1}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)}"
TABLE_NAME="${TABLE_NAME:-dynamodb-eio-live-test}"
USER_NAME="${USER_NAME:-sts-smoke-test-user}"
POLICY_NAME="dynamodb-eio-live-test"

echo "==> Creating DynamoDB table ${TABLE_NAME} (composite key pk/sk)..."
aws dynamodb create-table \
  --table-name "$TABLE_NAME" \
  --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sk,AttributeType=S \
  --key-schema AttributeName=pk,KeyType=HASH AttributeName=sk,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --region "$REGION" \
  --profile "$PROFILE" > /dev/null

echo "==> Waiting for the table to become ACTIVE..."
aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION" --profile "$PROFILE"

echo "==> Attaching inline policy to ${USER_NAME}..."
policy_file="$(mktemp)"
cat > "$policy_file" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DynamoDBLiveTestOnly",
      "Effect": "Allow",
      "Action": ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}"
    }
  ]
}
EOF
aws iam put-user-policy \
  --user-name "$USER_NAME" --policy-name "$POLICY_NAME" \
  --policy-document "file://${policy_file}" --profile "$PROFILE"
rm -f "$policy_file"

echo "==> Setup complete. DYNAMODB_EIO_LIVE_TABLE=${TABLE_NAME}"
