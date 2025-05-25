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
  default = "0.1.0"
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
  machine_type            = "e2-medium"
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

  provisioner "file" {
    source      = "config/kubeadm-init-ha.yaml"
    destination = "/tmp/kubeadm-init-ha.yaml"
  }

  provisioner "file" {
    source      = "config/kubeadm-init.yaml"
    destination = "/tmp/kubeadm-init.yaml"
  }

  provisioner "file" {
    source      = "config/master-join.yaml"
    destination = "/tmp/master-join.yaml"
  }

  provisioner "file" {
    source      = "config/worker-join.yaml"
    destination = "/tmp/worker-join.yaml"
  }

  provisioner "file" {
    source      = "scripts/init-kubernetes.sh"
    destination = "/tmp/init-kubernetes.sh"
  }

  provisioner "shell" {
    inline = [
      "sudo mv /tmp/kubeadm-init-ha.yaml /etc/kubeadm/kubeadm-init-ha.yaml",
      "sudo chmod 660 /etc/kubeadm/kubeadm-init-ha.yaml",
      "sudo chown root:root /etc/kubeadm/kubeadm-init-ha.yaml",
      "sudo mv /tmp/kubeadm-init.yaml /etc/kubeadm/kubeadm-init.yaml",
      "sudo chmod 660 /etc/kubeadm/kubeadm-init.yaml",
      "sudo chown root:root /etc/kubeadm/kubeadm-init.yaml",
      "sudo mv /tmp/master-join.yaml /etc/kubeadm/master-join.yaml",
      "sudo chmod 660 /etc/kubeadm/master-join.yaml",
      "sudo chown root:root /etc/kubeadm/master-join.yaml",
      "sudo mv /tmp/worker-join.yaml /etc/kubeadm/worker-join.yaml",
      "sudo chmod 660 /etc/kubeadm/worker-join.yaml",
      "sudo chown root:root /etc/kubeadm/worker-join.yaml",
      "sudo mv /tmp/init-kubernetes.sh /usr/local/bin/init-kubernetes.sh",
      "sudo chmod 550 /usr/local/bin/init-kubernetes.sh",
      "sudo chown root:root /usr/local/bin/init-kubernetes.sh"
    ]
  }

  provisioner "shell" {
    script          = "../../shared_scripts/cleanup.sh"
    execute_command = "sudo bash '{{.Path}}'"
  }
}
