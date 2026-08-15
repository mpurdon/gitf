# Token-protected Lambda function URL that starts the (idle-stopped)
# instance. Callable from a phone shortcut or:
#   curl "$(terraform output -raw wake_url)"
resource "random_password" "wake_token" {
  length  = 32
  special = false
}

data "archive_file" "wake" {
  type        = "zip"
  source_file = "${path.module}/lambda/index.py"
  output_path = "${path.module}/lambda/wake.zip"
}

resource "aws_iam_role" "wake" {
  name = "${var.project}-wake"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "wake_logs" {
  role       = aws_iam_role.wake.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "wake" {
  name = "${var.project}-wake"
  role = aws_iam_role.wake.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:StartInstances"]
      Resource = "*"
      Condition = {
        StringEquals = { "ec2:Region" = var.region }
      }
    }]
  })
}

resource "aws_lambda_function" "wake" {
  function_name    = "${var.project}-wake"
  role             = aws_iam_role.wake.arn
  runtime          = "python3.12"
  handler          = "index.handler"
  filename         = data.archive_file.wake.output_path
  source_code_hash = data.archive_file.wake.output_base64sha256
  timeout          = 10
  # No reserved concurrency: this new account's total limit (10) already
  # bounds abuse of the public InvokeFunction grant, and reserving any of
  # it breaches the unreserved minimum.

  environment {
    variables = {
      INSTANCE_ID = aws_instance.gitf.id
      WAKE_TOKEN  = random_password.wake_token.result
    }
  }
}

resource "aws_lambda_function_url" "wake" {
  function_name      = aws_lambda_function.wake.function_name
  authorization_type = "NONE" # the token in the query string is the auth
}

# Terraform does NOT auto-create the public-invoke grants the console adds
# for NONE-auth URLs; without them the URL front door 403s before the
# function (and its token check) ever runs. Function URLs created after
# October 2025 need BOTH statements (lambda:InvokeFunctionUrl AND
# lambda:InvokeFunction scoped to URL invocations).
resource "aws_lambda_permission" "wake_url_public" {
  statement_id           = "FunctionURLAllowPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.wake.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# TODO(provider >= 6.28): add `invoked_via_function_url = true` to scope
# this grant to URL invocations only (the arg doesn't exist in 5.x). Until
# then the grant is broader than ideal; the token check is the real gate,
# and reserved concurrency on the function bounds invoke-spam.
resource "aws_lambda_permission" "wake_url_public_invoke" {
  statement_id  = "FunctionURLInvokeAllowPublicAccess"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.wake.function_name
  principal     = "*"
}
