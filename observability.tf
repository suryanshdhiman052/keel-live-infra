data "aws_caller_identity" "current" {}

resource "aws_sns_topic" "ops" {
  name = "${local.name}-ops"
}

resource "aws_sns_topic_subscription" "ops_email" {
  topic_arn = aws_sns_topic.ops.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_policy" "ops" {
  arn = aws_sns_topic.ops.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowAwsPublish"
      Effect = "Allow"
      Principal = {
        Service = [
          "events.amazonaws.com",
          "cloudwatch.amazonaws.com",
          "rds.amazonaws.com",
        ]
      }
      Action   = "sns:Publish"
      Resource = aws_sns_topic.ops.arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

# No NAT: a dead endpoint/ECR/secret path stops NEW placements.
# Live tasks still pass /readyz, so ALB HealthyHostCount stays green.
resource "aws_cloudwatch_event_rule" "ecs_init_fail" {
  name = "${local.name}-ecs-init-fail"
  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn = [module.compute.cluster_arn]
      lastStatus = ["STOPPED"]
      stoppedReason = [
        { prefix = "CannotPullContainerError" },
        { prefix = "ResourceInitializationError" },
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "ecs_init_fail" {
  rule       = aws_cloudwatch_event_rule.ecs_init_fail.name
  arn        = aws_sns_topic.ops.arn
  depends_on = [aws_sns_topic_policy.ops]
}

resource "aws_cloudwatch_metric_alarm" "alb_no_ready" {
  alarm_name          = "${local.name}-alb-no-ready"
  alarm_description   = "Zero healthy targets. Typical: RDS down so /readyz returns 503."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.ops.arn]
  ok_actions          = [aws_sns_topic.ops.arn]

  metric_query {
    id          = "healthy"
    return_data = true
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HealthyHostCount"
      period      = 60
      stat        = "Minimum"
      dimensions = {
        LoadBalancer = module.compute.alb_full_name
        TargetGroup  = module.compute.target_group_full_name
      }
    }
  }
}

resource "aws_db_event_subscription" "rds_failure" {
  name             = "${local.name}-rds-failure"
  sns_topic        = aws_sns_topic.ops.arn
  source_type      = "db-instance"
  source_ids       = [module.database.identifier]
  event_categories = ["failure"]
  enabled          = true
  depends_on       = [aws_sns_topic_policy.ops]
}
