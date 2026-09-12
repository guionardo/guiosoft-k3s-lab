terraform {
  required_version = ">= 1.8.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.24"
    }
  }
}

provider "cloudflare" {
  # Authentication is intentionally supplied only through the
  # CLOUDFLARE_API_TOKEN environment variable.
}
