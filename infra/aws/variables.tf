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

variable "domain" {
  description = "Public domain for the factory (Route53 hosted zone is created for it)"
  type        = string
  default     = "ghostinthefactory.com"
}

variable "factory_tailnet_ip" {
  description = "Tailscale IP of the instance (100.x.y.z). Set after `tailscale up` to create the factory.<domain> A record; the name only resolves usefully inside the tailnet."
  type        = string
  default     = null
}

variable "google_site_verification" {
  description = "google-site-verification=... TXT value from the Workspace add-domain flow"
  type        = string
  default     = null
}

variable "monthly_budget_usd" {
  description = "Monthly account-wide spend budget (alerts at 50/80/100% actual + forecasted overrun)"
  type        = number
  default     = 100
}

variable "budget_email" {
  description = "Where AWS Budgets sends spend alerts"
  type        = string
  default     = "mdjpurdon@gmail.com"
}
