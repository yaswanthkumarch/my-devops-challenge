variable "namespace" {
  type        = string
  description = "Namespace to provision"
  default     = "devops-challenge"
}

variable "memory_quota" {
  type        = string
  description = "Total memory limit quota for the namespace"
  default     = "512Mi"
}

variable "api_token" {
  type        = string
  description = "API token consumed by the app; supply via TF_VAR_api_token. No default on purpose — no secret belongs in code."
  sensitive   = true
}
