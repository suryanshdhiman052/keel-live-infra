variable "label" { type = string }
variable "vpc_id" { type = string }
variable "ingress_ids" { type = list(string) }
variable "svc_ids" { type = list(string) }
variable "edge_sg" { type = string }
variable "tasks_sg" { type = string }
variable "fqdn" { type = string }
variable "dns_zone" { type = string }
variable "image_uri" { type = string }
variable "listen_port" { type = number }
variable "run_as" { type = string }
variable "replica_min" { type = number }
variable "secret_arn" { type = string }
variable "pg_address" { type = string }
variable "pg_port" { type = number }
variable "shop_db" { type = string }

data "aws_region" "current" {}
data "aws_caller_identity" "acct" {}

locals {
  pull_from   = var.image_uri != "" ? var.image_uri : "${aws_ecr_repository.shop.repository_url}:seed"
  numeric_uid = "1000:1000"
  streams     = "/ecs/${var.label}"

  web = {
    name  = "web"
    image = local.pull_from
    user  = local.numeric_uid
    portMappings = [{
      containerPort = var.listen_port
      protocol      = "tcp"
    }]
    environment = [
      { name = "PORT", value = tostring(var.listen_port) },
      { name = "DB_PORT", value = tostring(var.pg_port) },
      { name = "DB_NAME", value = var.shop_db },
      { name = "MEDIA_BUCKET", value = aws_s3_bucket.media.bucket },
      { name = "MEDIA_PREFIX", value = "media" },
    ]
    secrets = [
      { name = "DB_HOST", valueFrom = aws_ssm_parameter.pg_host.arn },
      { name = "DB_USERNAME", valueFrom = "${var.secret_arn}:username::" },
      { name = "DB_PASSWORD", valueFrom = "${var.secret_arn}:password::" },
    ]
    readonlyRootFilesystem = true
    privileged             = false
    mountPoints = [{
      sourceVolume  = "scratch"
      containerPath = "/tmp"
      readOnly      = false
    }]
    linuxParameters = {
      capabilities       = { drop = ["ALL"] }
      initProcessEnabled = true
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = local.streams
        awslogs-region        = data.aws_region.current.name
        awslogs-stream-prefix = "web"
      }
    }
  }
}

# Registry lives next to the task that pulls it. Object storage is not this.
resource "aws_ecr_repository" "shop" {
  name                 = var.label
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_s3_bucket" "media" {
  bucket = "${var.label}-media-${data.aws_caller_identity.acct.account_id}"
}

resource "aws_s3_bucket_public_access_block" "media" {
  bucket                  = aws_s3_bucket.media.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  bucket = aws_s3_bucket.media.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "tls_only" {
  bucket = aws_s3_bucket.media.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TlsOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.media.arn, "${aws_s3_bucket.media.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# After a rewind, overwrite this parameter and recycle tasks.
# The task family does not embed the RDS hostname.
resource "aws_ssm_parameter" "pg_host" {
  name  = "/${var.label}/pg-host"
  type  = "String"
  value = var.pg_address

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_acm_certificate" "shop" {
  domain_name       = var.fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "prove" {
  for_each = {
    for item in aws_acm_certificate.shop.domain_validation_options : item.domain_name => {
      name   = item.resource_record_name
      record = item.resource_record_value
      type   = item.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id         = var.dns_zone
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

resource "aws_acm_certificate_validation" "shop" {
  certificate_arn         = aws_acm_certificate.shop.arn
  validation_record_fqdns = [for row in aws_route53_record.prove : row.fqdn]
}

resource "aws_lb" "public" {
  name               = "${var.label}-lb"
  load_balancer_type = "application"
  internal           = false
  subnets            = var.ingress_ids
  security_groups    = [var.edge_sg]
}

resource "aws_lb_target_group" "web" {
  name        = "${var.label}-web"
  port        = var.listen_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path                = "/status"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "secure" {
  load_balancer_arn = aws_lb.public.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.shop.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

resource "aws_lb_listener" "plain" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_route53_record" "shop" {
  zone_id = var.dns_zone
  name    = var.fqdn
  type    = "A"

  alias {
    name                   = aws_lb.public.dns_name
    zone_id                = aws_lb.public.zone_id
    evaluate_target_health = true
  }
}

resource "aws_cloudwatch_log_group" "web" {
  name              = local.streams
  retention_in_days = 14
}

data "aws_iam_policy_document" "task_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "puller" {
  name               = "${var.label}-puller"
  assume_role_policy = data.aws_iam_policy_document.task_trust.json
}

resource "aws_iam_role_policy" "puller" {
  name = "puller"
  role = aws_iam_role.puller.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Stream"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.web.arn}:*"
      },
      {
        Sid      = "RegistryAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "RegistryPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = aws_ecr_repository.shop.arn
      },
      {
        Sid      = "PgSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.secret_arn
      },
      {
        Sid      = "PgHost"
        Effect   = "Allow"
        Action   = ["ssm:GetParameters", "ssm:GetParameter"]
        Resource = aws_ssm_parameter.pg_host.arn
      },
    ]
  })
}

resource "aws_iam_role" "worker" {
  name               = "${var.label}-worker"
  assume_role_policy = data.aws_iam_policy_document.task_trust.json
}

data "aws_iam_policy_document" "media_prefix" {
  statement {
    sid       = "ListMedia"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.media.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["media/", "media/*"]
    }
  }
  statement {
    sid       = "TouchMedia"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.media.arn}/media/*"]
  }
}

resource "aws_iam_role_policy" "media_prefix" {
  name   = "media-prefix"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.media_prefix.json
}

resource "aws_ecs_cluster" "shop" {
  name = var.label

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_task_definition" "web" {
  family                   = var.label
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.puller.arn
  task_role_arn            = aws_iam_role.worker.arn
  container_definitions    = jsonencode([local.web])

  volume {
    name = "scratch"
  }

  lifecycle {
    precondition {
      condition     = local.numeric_uid == "1000:1000" && var.run_as == "1000:1000"
      error_message = "The task JSON must set User 1000:1000. Image USER is not enough."
    }
  }
}

resource "aws_ecs_service" "web" {
  name                               = "${var.label}-web"
  cluster                            = aws_ecs_cluster.shop.id
  task_definition                    = aws_ecs_task_definition.web.arn
  desired_count                      = var.replica_min
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = var.svc_ids
    security_groups  = [var.tasks_sg]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.web.arn
    container_name   = "web"
    container_port   = var.listen_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.secure]

  lifecycle {
    ignore_changes = [desired_count]
  }
}

# Two on-demand copies. Spot was cheaper on paper and expensive in PENDING time.
resource "aws_appautoscaling_target" "web" {
  count              = var.replica_min > 0 ? 1 : 0
  max_capacity       = 3
  min_capacity       = max(var.replica_min, 2)
  resource_id        = "service/${aws_ecs_cluster.shop.name}/${aws_ecs_service.web.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu70" {
  count              = var.replica_min > 0 ? 1 : 0
  name               = "${var.label}-cpu70"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.web[0].resource_id
  scalable_dimension = aws_appautoscaling_target.web[0].scalable_dimension
  service_namespace  = aws_appautoscaling_target.web[0].service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70
    scale_in_cooldown  = 120
    scale_out_cooldown = 60
  }
}

output "registry" { value = aws_ecr_repository.shop.repository_url }
output "cluster" { value = aws_ecs_cluster.shop.name }
output "cluster_arn" { value = aws_ecs_cluster.shop.arn }
output "service" { value = aws_ecs_service.web.name }
output "pg_host_param" { value = aws_ssm_parameter.pg_host.name }
output "lb_suffix" { value = aws_lb.public.arn_suffix }
output "tg_suffix" { value = aws_lb_target_group.web.arn_suffix }
