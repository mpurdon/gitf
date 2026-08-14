# GiTF single-box AWS deployment.
#
# One Graviton EC2 instance, zero inbound (Tailscale is the front door),
# IAM role instead of resident keys, a persistent data volume, daily
# snapshots, an S3 backup bucket, and a token-protected wake Lambda so the
# idle-stopped instance can be started from a phone.
#
# See docs/deploy-aws.md for the full runbook.

terraform {
  required_version = ">= 1.10" # S3-native state locking (use_lockfile)

  # State lives in the GhostInTheFactory-Production account (515020252848).
  # Run terraform with AWS_PROFILE=gitf-prod (or gitf once SSO is set up).
  backend "s3" {
    bucket       = "gitf-terraform-state-515020252848"
    key          = "gitf/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = { Project = var.project }
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Pin one subnet deterministically (sorted, so the choice is stable across
# runs). Both the instance and the data volume derive their placement from
# this — never from each other — so replacing the instance can never cascade
# into destroying the data volume.
data "aws_subnet" "gitf" {
  id = sort(data.aws_subnets.default.ids)[0]
}

# Ubuntu 24.04 LTS arm64 — deliberately matches the ubuntu-24.04-arm CI
# runners that build the release tarball, so glibc/OpenSSL versions line up.
# Ubuntu 24.04 also ships bubblewrap with the AppArmor profile that permits
# its user namespaces, which the sandbox depends on.
data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}
