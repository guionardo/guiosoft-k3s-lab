variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the R2 bucket."
  type        = string
}

variable "r2_bucket_name" {
  description = "R2 bucket dedicated to encrypted Restic backups."
  type        = string
  default     = "guiosoft-k3s-backups"
}

variable "r2_location" {
  description = "Optional R2 location hint. Leave null to let Cloudflare choose automatically."
  type        = string
  default     = null
}
