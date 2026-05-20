variable "server_host" {
  description = "IP address or hostname of the target server where the stack will be installed"
  type        = string
}

variable "ssh_user" {
  description = "SSH user for connecting to the target server"
  type        = string
  default     = "appuser"
}

