# Provisions the one dedicated DynamoDB table + scoped IAM role
# dynamodb-eio's live test (test/test_dynamodb_live.ml, DYNAMODB_EIO_LIVE=1)
# needs. This package's own test infra, owned here because dynamodb-eio is a
# standalone package, not something living inside sun.
#
# No long-lived IAM access keys: the role is assumable by whatever
# principal(s) you name in trusted_principal_arns, via `aws sts assume-role`.
#
# Usage:
#   terraform init
#   terraform apply \
#     -var 'trusted_principal_arns=["arn:aws:iam::ACCOUNT_ID:user/you"]'
#
#   aws sts assume-role \
#     --role-arn "$(terraform output -raw role_arn)" \
#     --role-session-name dynamodb-eio-live-test
#   # export the returned AccessKeyId/SecretAccessKey/SessionToken, then:
#   DYNAMODB_EIO_LIVE=1 DYNAMODB_EIO_LIVE_TABLE="$(terraform output -raw table_name)" dune test
#
#   terraform destroy   # when done

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "table_name" {
  type    = string
  default = "dynamodb-eio-live-test"
}

variable "trusted_principal_arns" {
  type        = list(string)
  description = "ARNs allowed to assume the live-test role (your IAM user/role, or a CI OIDC role)"
}

provider "aws" {
  region = var.region
}

resource "aws_dynamodb_table" "live_test" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }
}

data "aws_iam_policy_document" "live_test" {
  statement {
    sid       = "DynamoDBLiveTestOnly"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.live_test.arn]
  }
}

resource "aws_iam_policy" "live_test" {
  name   = "dynamodb-eio-live-test"
  policy = data.aws_iam_policy_document.live_test.json
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = var.trusted_principal_arns
    }
  }
}

resource "aws_iam_role" "live_test" {
  name               = "dynamodb-eio-live-test"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachment" "live_test" {
  role       = aws_iam_role.live_test.name
  policy_arn = aws_iam_policy.live_test.arn
}

output "table_name" {
  value = aws_dynamodb_table.live_test.name
}

output "role_arn" {
  value = aws_iam_role.live_test.arn
}
