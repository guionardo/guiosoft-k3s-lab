variable "cloudflare_account_id" {
  description = "Cloudflare account ID."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for guiosoft.info."
  type        = string
}

variable "cloudflare_tunnel_id" {
  description = "Existing remotely managed Cloudflare Tunnel UUID."
  type        = string
}

variable "cloudflare_tunnel_name" {
  description = "Existing Cloudflare Tunnel name as shown in Zero Trust."
  type        = string
}

variable "cloudflare_wildcard_record_id" {
  description = "Existing DNS record ID for *.guiosoft.info. Used only by import instructions."
  type        = string
  default     = ""
}
