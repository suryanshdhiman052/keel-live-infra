variable "label" { type = string }
variable "persist_ids" { type = list(string) }
variable "postgres_sg" { type = string }
variable "shop_db" { type = string }
variable "shop_user" { type = string }

resource "aws_db_subnet_group" "persist" {
  name       = "${var.label}-persist"
  subnet_ids = var.persist_ids
}

resource "aws_db_parameter_group" "pg16" {
  name   = "${var.label}-pg16"
  family = "postgres16"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

# Budget pick: one AZ. Losing that AZ takes the shop offline until
# scripts/rewind-pg.sh writes a replacement and flips the SSM host.
resource "aws_db_instance" "pg" {
  identifier                  = "${var.label}-pg"
  engine                      = "postgres"
  engine_version              = "16"
  instance_class              = "db.t4g.micro"
  db_name                     = var.shop_db
  username                    = var.shop_user
  manage_master_user_password = true
  allocated_storage           = 20
  max_allocated_storage       = 40
  storage_type                = "gp3"
  storage_encrypted           = true
  db_subnet_group_name        = aws_db_subnet_group.persist.name
  vpc_security_group_ids      = [var.postgres_sg]
  publicly_accessible         = false
  multi_az                    = false
  parameter_group_name        = aws_db_parameter_group.pg16.name
  port                        = 5432
  backup_retention_period     = 7
  backup_window               = "08:00-09:00"
  delete_automated_backups    = false
  deletion_protection         = true
  skip_final_snapshot         = false
  final_snapshot_identifier   = "${var.label}-pg-last"

  lifecycle {
    ignore_changes = [snapshot_identifier]
  }
}

output "pg_id" { value = aws_db_instance.pg.id }
output "pg_address" { value = aws_db_instance.pg.address }
output "pg_port" { value = aws_db_instance.pg.port }
output "secret_arn" { value = aws_db_instance.pg.master_user_secret[0].secret_arn }
