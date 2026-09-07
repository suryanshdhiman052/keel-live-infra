variable "label" { type = string }
variable "vpc_cidr" { type = string }
variable "listen_port" { type = number }

data "aws_availability_zones" "usable" { state = "available" }
data "aws_region" "current" {}

locals {
  pair = slice(data.aws_availability_zones.usable.names, 0, 2)
}

resource "aws_vpc" "lan" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.label }
}

resource "aws_internet_gateway" "egress" {
  vpc_id = aws_vpc.lan.id
  tags   = { Name = var.label }
}

resource "aws_subnet" "ingress" {
  count                   = 2
  vpc_id                  = aws_vpc.lan.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = local.pair[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.label}-ingress-${local.pair[count.index]}" }
}

resource "aws_subnet" "svc" {
  count             = 2
  vpc_id            = aws_vpc.lan.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 4 + count.index)
  availability_zone = local.pair[count.index]
  tags              = { Name = "${var.label}-svc-${local.pair[count.index]}" }
}

resource "aws_subnet" "persist" {
  count             = 2
  vpc_id            = aws_vpc.lan.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 8 + count.index)
  availability_zone = local.pair[count.index]
  tags              = { Name = "${var.label}-persist-${local.pair[count.index]}" }
}

resource "aws_route_table" "edge" {
  vpc_id = aws_vpc.lan.id
  tags   = { Name = "${var.label}-edge" }
}

resource "aws_route" "edge_default" {
  route_table_id         = aws_route_table.edge.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.egress.id
}

resource "aws_route_table_association" "ingress" {
  count          = 2
  subnet_id      = aws_subnet.ingress[count.index].id
  route_table_id = aws_route_table.edge.id
}

# Isolated table has no default route. Workloads talk to AWS APIs through
# the endpoints below, never through a NAT gateway.
resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.lan.id
  tags   = { Name = "${var.label}-isolated" }
}

resource "aws_route_table_association" "svc" {
  count          = 2
  subnet_id      = aws_subnet.svc[count.index].id
  route_table_id = aws_route_table.isolated.id
}

resource "aws_route_table_association" "persist" {
  count          = 2
  subnet_id      = aws_subnet.persist[count.index].id
  route_table_id = aws_route_table.isolated.id
}

resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id            = aws_vpc.lan.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.isolated.id]
}

resource "aws_security_group" "privatelink" {
  name   = "${var.label}-privatelink"
  vpc_id = aws_vpc.lan.id
}

resource "aws_vpc_endpoint" "aws_apis" {
  for_each = toset(["ecr.api", "ecr.dkr", "logs", "secretsmanager", "ssm"])

  vpc_id              = aws_vpc.lan.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.svc[*].id
  security_group_ids  = [aws_security_group.privatelink.id]
  private_dns_enabled = true
}

resource "aws_security_group" "edge" {
  name   = "${var.label}-edge"
  vpc_id = aws_vpc.lan.id
}

resource "aws_security_group" "tasks" {
  name   = "${var.label}-tasks"
  vpc_id = aws_vpc.lan.id
}

resource "aws_security_group" "postgres" {
  name   = "${var.label}-postgres"
  vpc_id = aws_vpc.lan.id
}

resource "aws_vpc_security_group_ingress_rule" "edge_http_in" {
  security_group_id = aws_security_group.edge.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "edge_https_in" {
  security_group_id = aws_security_group.edge.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "edge_forward" {
  security_group_id            = aws_security_group.edge.id
  ip_protocol                  = "tcp"
  from_port                    = var.listen_port
  to_port                      = var.listen_port
  referenced_security_group_id = aws_security_group.tasks.id
}

resource "aws_vpc_security_group_ingress_rule" "tasks_accept_edge" {
  security_group_id            = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = var.listen_port
  to_port                      = var.listen_port
  referenced_security_group_id = aws_security_group.edge.id
}

resource "aws_vpc_security_group_egress_rule" "tasks_pg_out" {
  security_group_id            = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.postgres.id
}

resource "aws_vpc_security_group_ingress_rule" "pg_accept_tasks" {
  security_group_id            = aws_security_group.postgres.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.tasks.id
}

resource "aws_vpc_security_group_egress_rule" "tasks_privatelink_out" {
  security_group_id            = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.privatelink.id
}

resource "aws_vpc_security_group_ingress_rule" "privatelink_accept_tasks" {
  security_group_id            = aws_security_group.privatelink.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.tasks.id
}

resource "aws_vpc_security_group_egress_rule" "tasks_resolver" {
  for_each          = toset(["tcp", "udp"])
  security_group_id = aws_security_group.tasks.id
  ip_protocol       = each.key
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = var.vpc_cidr
}

data "aws_prefix_list" "s3" {
  name = "com.amazonaws.${data.aws_region.current.name}.s3"
}

resource "aws_vpc_security_group_egress_rule" "tasks_s3_layers" {
  security_group_id = aws_security_group.tasks.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = data.aws_prefix_list.s3.id
}

output "vpc_id" { value = aws_vpc.lan.id }
output "ingress_ids" { value = aws_subnet.ingress[*].id }
output "svc_ids" { value = aws_subnet.svc[*].id }
output "persist_ids" { value = aws_subnet.persist[*].id }
output "edge_sg" { value = aws_security_group.edge.id }
output "tasks_sg" { value = aws_security_group.tasks.id }
output "postgres_sg" { value = aws_security_group.postgres.id }
