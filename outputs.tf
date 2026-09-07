output "vpc_id" {
  value = module.networking.vpc_id
}

output "ecr_repository_url" {
  value = module.compute.ecr_repository_url
}

output "api_hostname" {
  value = var.domain_name
}

output "db_endpoint_parameter" {
  value = module.compute.db_endpoint_parameter
}

output "cluster_name" {
  value = module.compute.cluster_name
}

output "service_name" {
  value = module.compute.service_name
}

output "sns_topic_arn" {
  value = aws_sns_topic.ops.arn
}
