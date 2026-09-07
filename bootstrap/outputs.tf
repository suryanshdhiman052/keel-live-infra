output "bucket" {
  value = aws_s3_bucket.remote.id
}

output "mutex" {
  value = aws_dynamodb_table.mutex.name
}

output "backend_hcl" {
  value = <<-EOT
    bucket         = "${aws_s3_bucket.remote.id}"
    key            = "keel/shop/terraform.tfstate"
    region         = "${var.aws_region}"
    dynamodb_table = "${aws_dynamodb_table.mutex.name}"
    encrypt        = true
  EOT
}
