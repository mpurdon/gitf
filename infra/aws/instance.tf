# Zero-inbound security group: Tailscale's outbound tunnel is the only way
# in. The public IP exists for egress only (a NAT gateway costs ~$32/mo and
# would sink the budget on its own).
resource "aws_security_group" "gitf" {
  name        = "${var.project}-no-inbound"
  description = "GiTF: no inbound; all egress"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "gitf" {
  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.gitf.id]
  iam_instance_profile   = aws_iam_instance_profile.gitf.name

  associate_public_ip_address = true

  # `systemctl poweroff` from the idle-stop timer must STOP the instance
  # (billing drops to EBS), not terminate it.
  instance_initiated_shutdown_behavior = "stop"

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 12
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    backup_bucket = aws_s3_bucket.backup.bucket
  })

  tags = { Name = var.project }

  lifecycle {
    # AMI updates roll via `terraform apply -replace`; don't churn the box
    # every time Canonical publishes a new image.
    ignore_changes = [ami]
  }
}

# Persistent data volume: survives instance replacement. Mounted at
# /var/lib/gitf, which is the gitf user's HOME — so the store
# (~/.gitf/store), the global config (~/.config/gitf), and sector repos all
# live on it.
resource "aws_ebs_volume" "data" {
  availability_zone = aws_instance.gitf.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"

  tags = {
    Name   = "${var.project}-data"
    Backup = var.project
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.gitf.id
}

# Daily snapshot of the data volume, retained snapshot_retain_days.
resource "aws_iam_role" "dlm" {
  name = "${var.project}-dlm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "data" {
  description        = "Daily ${var.project} data-volume snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Backup = var.project }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["09:00"]
      }

      retain_rule {
        count = var.snapshot_retain_days
      }

      copy_tags = true
    }
  }
}
