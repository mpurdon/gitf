variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "Graviton instance type. t4g.small (2 GB) fits the control plane and 1-2 API-mode ghosts; move to t4g.medium if validation builds thrash."
  type        = string
  default     = "t4g.small"
}

variable "data_volume_gb" {
  description = "Size of the persistent data volume mounted at /var/lib/gitf"
  type        = number
  default     = 40
}

variable "project" {
  description = "Tag applied to every resource"
  type        = string
  default     = "gitf"
}

variable "snapshot_retain_days" {
  description = "How many daily EBS snapshots of the data volume to keep"
  type        = number
  default     = 7
}
