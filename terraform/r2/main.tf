resource "cloudflare_r2_bucket" "k3s_backups" {
  account_id    = var.cloudflare_account_id
  name          = var.r2_bucket_name
  location      = var.r2_location
  storage_class = "Standard"

  lifecycle {
    prevent_destroy = true
  }
}

output "r2_bucket_name" {
  value = cloudflare_r2_bucket.k3s_backups.name
}
