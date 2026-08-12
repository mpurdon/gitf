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
      Action   = ["ec2:StartInstances", "ec2:DescribeInstances"]
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
