output "firecrawl_hermes_client_id" {
  description = "Cloudflare Access Client ID for the Hermes Firecrawl consumer."
  value       = cloudflare_zero_trust_access_service_token.firecrawl_hermes.client_id
}

output "firecrawl_hermes_client_secret" {
  description = "Cloudflare Access Client Secret for the Hermes Firecrawl consumer."
  value       = cloudflare_zero_trust_access_service_token.firecrawl_hermes.client_secret
  sensitive   = true
}

output "firecrawl_opencode_client_id" {
  description = "Cloudflare Access Client ID for the OpenCode Firecrawl consumer."
  value       = cloudflare_zero_trust_access_service_token.firecrawl_opencode.client_id
}

output "firecrawl_opencode_client_secret" {
  description = "Cloudflare Access Client Secret for the OpenCode Firecrawl consumer."
  value       = cloudflare_zero_trust_access_service_token.firecrawl_opencode.client_secret
  sensitive   = true
}
