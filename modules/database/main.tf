variable "name" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "rds_sg_id" { type = string }
variable "db_name" { type = string }
variable "username" { type = string }

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-pg"
  subnet_ids = var.private_subnet_ids
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-pg16"
  family = "postgres16"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

# $150 trade-off: single-AZ db.t4g.micro. AZ loss is a full outage.
# Never set snapshot_identifier here (ForceNew) during an incident.
resource "aws_db_instance" "this" {
  identifier                  = "${var.name}-pg"
  engine                      = "postgres"
  engine_version              = "16"
  instance_class              = "db.t4g.micro"
  db_name                     = var.db_name
  username                    = var.username
  manage_master_user_password = true
  allocated_storage           = 20
  max_allocated_storage       = 40
  storage_type                = "gp3"
  storage_encrypted           = true
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [var.rds_sg_id]
  publicly_accessible         = false
  multi_az                    = false
  parameter_group_name        = aws_db_parameter_group.this.name
  port                        = 5432
  backup_retention_period     = 7
  backup_window               = "06:00-07:00"
  delete_automated_backups    = false
  deletion_protection         = true
  skip_final_snapshot         = false
  final_snapshot_identifier   = "${var.name}-pg-final"

  lifecycle {
    ignore_changes = [snapshot_identifier]
  }
}

output "identifier" { value = aws_db_instance.this.id }
output "address" { value = aws_db_instance.this.address }
output "port" { value = aws_db_instance.this.port }
output "master_user_secret_arn" { value = aws_db_instance.this.master_user_secret[0].secret_arn }
