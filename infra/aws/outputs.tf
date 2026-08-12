output "instance_id" {
  value = aws_instance.gitf.id
}

output "ssm_session" {
  description = "Shell on the box (no SSH, no open ports)"
  value       = "aws ssm start-session --target ${aws_instance.gitf.id} --region ${var.region}"
}

output "backup_bucket" {
  value = aws_s3_bucket.backup.bucket
}

output "wake_url" {
  description = "GET this URL to start a stopped instance. The token is the auth — treat the URL as a secret."
  value       = "${aws_lambda_function_url.wake.function_url}?token=${random_password.wake_token.result}"
  sensitive   = true
}
