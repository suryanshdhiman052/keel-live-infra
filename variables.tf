variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "keel"
}

variable "stage" {
  type    = string
  default = "shop"
}

variable "vpc_cidr" {
  type    = string
  default = "172.20.16.0/20"
}

variable "fqdn" {
  type = string
}

variable "dns_zone" {
  type = string
}

variable "pager_email" {
  type = string
}

variable "image_uri" {
  type    = string
  default = ""
}

variable "listen_port" {
  type    = number
  default = 8088
}

variable "run_as" {
  type    = string
  default = "1000:1000"

  validation {
    condition     = var.run_as == "1000:1000"
    error_message = "Fargate User must be numeric 1000:1000."
  }
}

variable "replica_min" {
  type    = number
  default = 0

  validation {
    condition     = var.replica_min >= 0 && var.replica_min <= 3
    error_message = "replica_min stays 0 until the first immutable tag is pushed."
  }
}

variable "shop_db" {
  type    = string
  default = "shopdb"
}

variable "shop_user" {
  type    = string
  default = "shopuser"
}
