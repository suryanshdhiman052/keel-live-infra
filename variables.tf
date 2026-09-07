variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "keel"
}

variable "environment" {
  type    = string
  default = "live"
}

variable "vpc_cidr" {
  type    = string
  default = "10.81.0.0/16"
}

variable "domain_name" {
  type = string
}

variable "hosted_zone_id" {
  type = string
}

variable "alert_email" {
  type = string
}

variable "container_image" {
  type    = string
  default = ""
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "container_user" {
  type    = string
  default = "1000:1000"

  validation {
    condition     = var.container_user == "1000:1000"
    error_message = "Runtime user is hardcoded to UID 1000. Do not pass root, 0, or an image USER name."
  }
}

variable "desired_count" {
  type    = number
  default = 0

  validation {
    condition     = var.desired_count >= 0 && var.desired_count <= 3
    error_message = "desired_count must be 0-3. 0 is required until the ECR tag exists."
  }
}

variable "db_name" {
  type    = string
  default = "keelshop"
}

variable "db_username" {
  type    = string
  default = "keelapp"
}
