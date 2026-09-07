data "aws_caller_identity" "acct" {}

resource "aws_sns_topic" "pager" {
  name = "${local.label}-pager"
}

resource "aws_sns_topic_subscription" "inbox" {
  topic_arn = aws_sns_topic.pager.arn
  protocol  = "email"
  endpoint  = var.pager_email
}

resource "aws_sns_topic_policy" "pager" {
  arn = aws_sns_topic.pager.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ServicesMayPublish"
      Effect = "Allow"
      Principal = {
        Service = [
          "events.amazonaws.com",
          "cloudwatch.amazonaws.com",
          "rds.amazonaws.com",
        ]
      }
      Action   = "sns:Publish"
      Resource = aws_sns_topic.pager.arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.acct.account_id }
      }
    }]
  })
}

# Placement dies without NAT/endpoints. Running tasks still answer /status,
# so a host-count alarm alone would stay quiet.
resource "aws_cloudwatch_event_rule" "task_never_started" {
  name = "${local.label}-task-never-started"
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

resource "aws_cloudwatch_event_target" "task_never_started" {
  rule       = aws_cloudwatch_event_rule.task_never_started.name
  arn        = aws_sns_topic.pager.arn
  depends_on = [aws_sns_topic_policy.pager]
}

resource "aws_cloudwatch_metric_alarm" "no_ready_targets" {
  alarm_name          = "${local.label}-no-ready-targets"
  alarm_description   = "Target group empty. Usually /status cannot open Postgres."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.pager.arn]
  ok_actions          = [aws_sns_topic.pager.arn]

  metric_query {
    id          = "ready"
    return_data = true
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HealthyHostCount"
      period      = 60
      stat        = "Minimum"
      dimensions = {
        LoadBalancer = module.compute.lb_suffix
        TargetGroup  = module.compute.tg_suffix
      }
    }
  }
}

resource "aws_db_event_subscription" "pg_failure" {
  name             = "${local.label}-pg-failure"
  sns_topic        = aws_sns_topic.pager.arn
  source_type      = "db-instance"
  source_ids       = [module.database.pg_id]
  event_categories = ["failure"]
  enabled          = true
  depends_on       = [aws_sns_topic_policy.pager]
}
