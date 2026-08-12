# Instance role: SSM Session Manager (no SSH), Parameter Store secrets,
# Bedrock invocation (BedrockDirect speaks SigV4 — Anthropic models with no
# API key on the box), and the backup bucket.

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gitf" {
  name               = "${var.project}-instance"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.gitf.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "gitf" {
  statement {
    sid       = "ReadGitfParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${var.region}:*:parameter/${var.project}/*"]
  }

  statement {
    sid = "InvokeBedrock"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ]
    resources = ["*"]
  }

  statement {
    sid = "BackupBucket"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.backup.arn,
      "${aws_s3_bucket.backup.arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "gitf" {
  name   = "${var.project}-instance"
  role   = aws_iam_role.gitf.id
  policy = data.aws_iam_policy_document.gitf.json
}

resource "aws_iam_instance_profile" "gitf" {
  name = "${var.project}-instance"
  role = aws_iam_role.gitf.name
}
