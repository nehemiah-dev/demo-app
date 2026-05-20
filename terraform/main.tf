terraform {
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

resource "null_resource" "install_app_stack" {

  triggers = {
    always_run = timestamp()
  }

  connection {
    type        = "ssh"
    host        = var.server_host
    user        = var.ssh_user
    private_key = file(pathexpand("~/.ssh/id_ed25519"))
  }

  provisioner "file" {
    source      = "${path.module}/../demo-app.zip"
    destination = "/tmp/demo-app.zip"
  }

  provisioner "remote-exec" {
    inline = [
      "echo I am sooooo tired",
      # Install unzip if missing
      "sudo apt-get update",
      "sudo apt-get install -y unzip",

      # Clean old deployment
      "sudo rm -rf /opt/demo-app",

      # Create destination
      "sudo mkdir -p /opt/demo-app",

      # Extract archive
      "sudo unzip -o /tmp/demo-app.zip -d /opt/demo-app",

      # Fix ownership
      "sudo chown -R ${var.ssh_user}:${var.ssh_user} /opt/demo-app",

      # Make install executable
      "chmod +x /opt/demo-app/scripts/install.sh",

      # Run install
      "sudo bash /opt/demo-app/scripts/install.sh"
    ]
  }
}
