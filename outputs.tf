output "vpc_id" {
  value = module.networking.vpc_id
}

output "registry" {
  value = module.compute.registry
}

output "shop_url" {
  value = var.fqdn
}

output "pg_host_param" {
  value = module.compute.pg_host_param
}

output "cluster" {
  value = module.compute.cluster
}

output "service" {
  value = module.compute.service
}

output "pager_topic" {
  value = aws_sns_topic.pager.arn
}
