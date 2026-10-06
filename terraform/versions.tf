terraform {
  # ~> 1.5: accepts 1.x patch updates, blocks surprise 2.x language changes.
  required_version = "~> 1.5"

  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      # Exact pin: provider minor bumps have changed default behaviors and
      # produced plan diffs before; plans must be reproducible.
      version = "2.36.0"
    }
  }
}

provider "kubernetes" {
  config_path = "~/.kube/config"
}
