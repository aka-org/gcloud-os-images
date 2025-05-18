packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = ">= 1.0.0"
    }
  }
}

variable "project_id" {
  type = string
}
variable "build_version" {
  type = string
}

variable "zone" {
  type    = string
  default = "us-east1-b"
}

variable "image_family" {
  type    = string
  default = "kubernetes-node"
}

variable "base_version" {
  type    = string
  default = "1.0.0"
}
variable "subnetwork" {
  type    = string
  default = "infra-public"
}

variable "network_tags" {
  type    = list(string)
  default = ["ssh"]
}

locals {
  image_version = replace("${var.base_version}-${var.build_version}", ".", "-")
  image_name    = "${var.image_family}-${local.image_version}"
}

source "googlecompute" "debian" {
  project_id              = var.project_id
  source_image            = "debian-12-bookworm-v20250415"
  source_image_project_id = ["debian-cloud"]
  zone                    = var.zone
  machine_type            = "e2-micro"
  disk_size               = 10
  image_name              = local.image_name
  image_family            = var.image_family
  communicator            = "ssh"
  temporary_key_pair_type = "ed25519"
  ssh_username            = "packer"
  subnetwork              = var.subnetwork
  tags                    = var.network_tags

  image_labels = {
    version    = local.image_version
    created_by = "packer"
  }
}

build {
  sources = ["source.googlecompute.debian"]

  provisioner "shell" {
    script          = "../../shared_scripts/common.sh"
    execute_command = "sudo bash '{{.Path}}'"
  }

  provisioner "shell" {
    script          = "scripts/setup-kubernetes.sh"
    execute_command = "sudo bash '{{.Path}}'"
  }

  provisioner "shell" {
    script          = "../../shared_scripts/cleanup.sh"
    execute_command = "sudo bash '{{.Path}}'"
  }
}
