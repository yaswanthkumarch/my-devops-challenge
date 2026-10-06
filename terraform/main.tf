resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace
  }
}

# Quota keys mirror what the chart's containers must declare: with a
# requests/limits key present, admission REJECTS any pod that omits them —
# the original limits.memory-only quota silently blocked the rootless pod.
resource "kubernetes_resource_quota" "memory" {
  metadata {
    name      = "memory-quota"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = "250m"
      "requests.memory" = "512Mi"
      "limits.cpu"      = "500m"
      "limits.memory"   = var.memory_quota
    }
  }
}

# Single owner of the secret: Terraform. Helm references it by name
# (helm/skybyte-app/values.yaml -> secretName). The value comes from
# TF_VAR_api_token (sensitive var, NO default) — nothing in git.
# Accepted tradeoff: the value is still plaintext in terraform.tfstate
# (documented in DECISIONS.md).
resource "kubernetes_secret" "api_token" {
  metadata {
    name      = "api-token"
    namespace = kubernetes_namespace.this.metadata[0].name
  }

  data = {
    token = var.api_token
  }

  type = "Opaque"
}
