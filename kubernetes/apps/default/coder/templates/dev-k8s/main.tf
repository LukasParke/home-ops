terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 0.23"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.29"
    }
  }
}

# The coder server provisions workspaces from inside the cluster, so the
# provider uses in-cluster config via its ServiceAccount (rbac.yaml grants
# the required namespace/pod/PVC permissions).
provider "kubernetes" {}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "image" {
  name         = "image"
  display_name = "Workspace image"
  description  = "Base image for the dev container"
  default      = "ghcr.io/lukasparke/coder-dev:24.04"
  mutable      = true
  order        = 1

  option {
    name  = "Home dev (prebuilt toolchain)"
    value = "ghcr.io/lukasparke/coder-dev:24.04"
    icon  = "/icon/container.svg"
  }
  option {
    name  = "Ubuntu 24.04 (minimal)"
    value = "docker.io/library/ubuntu:24.04"
    icon  = "/icon/ubuntu.svg"
  }
  option {
    name  = "Debian stable (minimal)"
    value = "docker.io/library/debian:stable"
    icon  = "/icon/debian.svg"
  }
  option {
    name  = "Arch Linux (minimal)"
    value = "docker.io/library/archlinux:base-devel"
    icon  = "/icon/arch-linux.png"
  }
}

data "coder_parameter" "cpu" {
  name         = "cpu"
  display_name = "CPU cores"
  type         = "number"
  default      = 2
  mutable      = true
  order        = 2

  validation {
    min = 1
    max = 4
  }
}

data "coder_parameter" "memory" {
  name         = "memory"
  display_name = "Memory (GiB)"
  type         = "number"
  default      = 4
  mutable      = true
  order        = 3

  validation {
    min = 1
    max = 8
  }
}

data "coder_parameter" "home_disk" {
  name         = "home_disk"
  display_name = "Home disk (GiB)"
  description  = "Persistent volume mounted at /home/coder; survives stop/start"
  type         = "number"
  default      = 10
  mutable      = false
  order        = 4

  validation {
    min = 1
    max = 50
  }
}

data "coder_parameter" "dotfiles_uri" {
  name         = "dotfiles_uri"
  display_name = "Dotfiles repo (optional)"
  description  = "Public git URL cloned into the home directory on first start"
  default      = ""
  mutable      = true
  order        = 5
}

# Autostop is a template-level setting (not a Terraform attribute in this
# provider): pass --default-ttl 8h to `coder templates create/push`.

locals {
  workspace_name = lower("coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}")
  workspace_labels = {
    "app.kubernetes.io/managed-by" = "coder"
    "coder.workspace.id"           = data.coder_workspace.me.id
    "coder.workspace.name"         = data.coder_workspace.me.name
    "coder.owner.id"               = data.coder_workspace_owner.me.id
    "coder.owner.username"         = data.coder_workspace_owner.me.name
  }
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = data.coder_provisioner.me.arch

  startup_script = data.coder_parameter.dotfiles_uri.value != "" ? "coder dotfiles -y ${data.coder_parameter.dotfiles_uri.value}" : null
}

# One namespace per workspace: torn down with the workspace, keeps workspaces
# and their pods/PVCs separate from the apps in the default namespace.
resource "kubernetes_namespace" "workspace" {
  metadata {
    name   = local.workspace_name
    labels = local.workspace_labels
  }
}

# The home directory is the only persistent part — the pod itself is ephemeral.
resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "home"
    namespace = kubernetes_namespace.workspace.metadata[0].name
    labels    = local.workspace_labels
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "ceph-rbd"

    resources {
      requests = {
        storage = "${data.coder_parameter.home_disk.value}Gi"
      }
    }
  }
}

resource "kubernetes_pod" "workspace" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = local.workspace_name
    namespace = kubernetes_namespace.workspace.metadata[0].name
    labels    = merge(local.workspace_labels, { "coder.workspace_id" = data.coder_workspace.me.id })
  }

  spec {
    container {
      name    = "dev"
      image   = data.coder_parameter.image.value
      command = ["sh", "-c", coder_agent.main.init_script]

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      resources {
        requests = {
          cpu    = data.coder_parameter.cpu.value
          memory = "${data.coder_parameter.memory.value}Gi"
        }
        limits = {
          cpu    = data.coder_parameter.cpu.value
          memory = "${data.coder_parameter.memory.value}Gi"
        }
      }

      volume_mount {
        name       = "home"
        mount_path = "/home/coder"
      }
    }

    volume {
      name = "home"

      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home.metadata[0].name
      }
    }
  }
}

output "pod" {
  value = one(kubernetes_pod.workspace[*].metadata[0].name)
}
