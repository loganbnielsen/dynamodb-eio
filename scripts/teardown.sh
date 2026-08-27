#!/usr/bin/env bash
# Tears down everything setup.sh creates. Best-effort (|| true throughout) —
# safe to re-run if a previous teardown partially failed.
set -uo pipefail

PROFILE="${PROFILE:-sts-smoke-test-provisioner}"
REGION="${REGION:-us-east-1}"
TABLE_NAME="${TABLE_NAME:-dynamodb-eio-live-test}"
USER_NAME="${USER_NAME:-sts-smoke-test-user}"
POLICY_NAME="dynamodb-eio-live-test"

echo "==> Detaching inline policy from ${USER_NAME}..."
aws iam delete-user-policy --user-name "$USER_NAME" --policy-name "$POLICY_NAME" --profile "$PROFILE" || true

echo "==> Deleting DynamoDB table ${TABLE_NAME}..."
aws dynamodb delete-table --table-name "$TABLE_NAME" --region "$REGION" --profile "$PROFILE" > /dev/null || true
aws dynamodb wait table-not-exists --table-name "$TABLE_NAME" --region "$REGION" --profile "$PROFILE" || true

echo "==> Teardown complete."
