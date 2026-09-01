# The Cabinet — the fleet's always-on front door (docs/plans/ministry.md).
#
# A t4g.micro running the same release in cabinet mode: registry, webhook
# ingress, activation ruleset, wake/stop for ministry boxes. It is the
# fleet's ONLY always-on cost; every ministry Section sleeps to $0.
#
# Reuses the factory's zero-inbound security group, subnet, AMI, and
# bootstrap template. Its own small data volume keeps the /var/lib/gitf
# layout identical so rel/install-systemd.sh works unmodified.

variable "cabinet_instance_type" {
  description = "Cabinet instance type. 1 GiB (t4g.micro) — nano's 0.5 GiB is too tight for BEAM + tailscaled."
  type        = string
  default     = "t4g.micro"
}

variable "cabinet_tailnet_ip" {
  description = "Tailscale IP of the cabinet (100.x.y.z). Set after `tailscale up` to create cabinet.<domain>."
  type        = string
  default     = null
}

resource "aws_instance" "cabinet" {
  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = var.cabinet_instance_type
  subnet_id              = data.aws_subnet.gitf.id
  vpc_security_group_ids = [aws_security_group.gitf.id]
  iam_instance_profile   = aws_iam_instance_profile.cabinet.name

  associate_public_ip_address = true

  # The Cabinet is always-on by design, but if anything ever powers it off
  # it must stop (EBS-only billing), never terminate.
  instance_initiated_shutdown_behavior = "stop"

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    backup_bucket = aws_s3_bucket.backup.bucket
  })

  tags = { Name = "${var.project}-cabinet" }

  lifecycle {
    ignore_changes = [ami]
    # A replacement throws away the root volume (release, /etc/gitf/gitf.env,
    # tailscale identity, Caddy). The factory was silently replaced on
    # 2026-09-01 by an apply whose plan nobody read; never again — a
    # deliberate rebuild removes this line for one apply.
    prevent_destroy = true
  }
}

resource "aws_ebs_volume" "cabinet_data" {
  availability_zone = data.aws_subnet.gitf.availability_zone
  size              = 4
  type              = "gp3"

  tags = { Name = "${var.project}-cabinet-data" }
}

resource "aws_volume_attachment" "cabinet_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.cabinet_data.id
  instance_id = aws_instance.cabinet.id
}

# Cabinet instance role: SSM (session + parameters), and Start/Stop scoped
# to instances tagged as ministries — Describe has no resource-level
# support, so it is account-wide read-only.
resource "aws_iam_role" "cabinet" {
  name               = "${var.project}-cabinet"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy_attachment" "cabinet_ssm" {
  role       = aws_iam_role.cabinet.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "cabinet" {
  statement {
    sid       = "ReadGitfParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${var.region}:*:parameter/${var.project}/*"]
  }

  # Ministry webhook secrets are minted on the Cabinet and handed to the
  # ministry box through Parameter Store, never through an operator session.
  statement {
    sid       = "PublishCabinetParameters"
    actions   = ["ssm:PutParameter"]
    resources = ["arn:aws:ssm:${var.region}:*:parameter/${var.project}/cabinet/*"]
  }

  statement {
    sid       = "DescribeInstances"
    actions   = ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"]
    resources = ["*"]
  }

  statement {
    sid       = "StartStopMinistries"
    actions   = ["ec2:StartInstances", "ec2:StopInstances"]
    resources = ["arn:aws:ec2:${var.region}:*:instance/*"]

    condition {
      test     = "StringLike"
      variable = "aws:ResourceTag/gitf:ministry"
      values   = ["*"]
    }
  }

  # Release tarballs live in the backup bucket (artifacts/); read-only.
  statement {
    sid       = "ReadReleaseArtifacts"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.backup.arn, "${aws_s3_bucket.backup.arn}/*"]
  }

  # DNS-01 for the cabinet.<domain> certificate, same as the factory.
  statement {
    sid = "Dns01ChallengeZone"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets"
    ]
    resources = [aws_route53_zone.main.arn]
  }

  statement {
    sid = "Dns01ChallengeGlobal"
    actions = [
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:GetChange"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "cabinet" {
  name   = "${var.project}-cabinet"
  role   = aws_iam_role.cabinet.id
  policy = data.aws_iam_policy_document.cabinet.json
}

resource "aws_iam_instance_profile" "cabinet" {
  name = "${var.project}-cabinet"
  role = aws_iam_role.cabinet.name
}

resource "aws_route53_record" "cabinet" {
  count = var.cabinet_tailnet_ip == null ? 0 : 1

  zone_id = aws_route53_zone.main.zone_id
  name    = "cabinet.${var.domain}"
  type    = "A"
  ttl     = 300
  records = [var.cabinet_tailnet_ip]
}

output "cabinet_instance_id" {
  value = aws_instance.cabinet.id
}

output "cabinet_ssm_session" {
  value = "aws ssm start-session --target ${aws_instance.cabinet.id} --region ${var.region}"
}
