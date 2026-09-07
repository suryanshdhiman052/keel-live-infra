locals {
  label = "${var.project}-${var.stage}"
}

module "networking" {
  source      = "./modules/networking"
  label       = local.label
  vpc_cidr    = var.vpc_cidr
  listen_port = var.listen_port
}

module "database" {
  source      = "./modules/database"
  label       = local.label
  persist_ids = module.networking.persist_ids
  postgres_sg = module.networking.postgres_sg
  shop_db     = var.shop_db
  shop_user   = var.shop_user
}

module "compute" {
  source      = "./modules/compute"
  label       = local.label
  vpc_id      = module.networking.vpc_id
  ingress_ids = module.networking.ingress_ids
  svc_ids     = module.networking.svc_ids
  edge_sg     = module.networking.edge_sg
  tasks_sg    = module.networking.tasks_sg
  fqdn        = var.fqdn
  dns_zone    = var.dns_zone
  image_uri   = var.image_uri
  listen_port = var.listen_port
  run_as      = var.run_as
  replica_min = var.replica_min
  secret_arn  = module.database.secret_arn
  pg_address  = module.database.pg_address
  pg_port     = module.database.pg_port
  shop_db     = var.shop_db
}
