module "database" {
  source = "./modules/database"
}
module "queue" {
  source = "./modules/queue"
}
module "iam" {
  source         = "./modules/iam"
  jobs_table_arn = module.database.jobs_table_arn
  grid_table_arn = module.database.grid_table_arn
  queue_arn      = module.queue.queue_arn
}
module "lambdas" {
  source          = "./modules/lambdas"
  lambda_role_arn = module.iam.lambda_role_arn
  jobs_table_name = module.database.jobs_table_name
  grid_table_name = module.database.grid_table_name
  queue_url       = module.queue.queue_url
}

output "api_url" {
  value = module.lambdas.api_url
}

module "workers" {
  source                = "./modules/workers"
  instance_profile_name = module.iam.worker_instance_profile_name
  jobs_table_name       = module.database.jobs_table_name
  grid_table_name       = module.database.grid_table_name
  queue_url             = module.queue.queue_url
  queue_name            = module.queue.queue_name
}

module "monitoring" {
  source                = "./modules/monitoring"
  instance_profile_name = module.iam.monitoring_instance_profile_name
  jobs_table_name       = module.database.jobs_table_name
  grid_table_name       = module.database.grid_table_name
  queue_url             = module.queue.queue_url
  region                = var.aws_region

  depends_on = [module.iam]
}

output "monitoring_instance_id" {
  value = module.monitoring.instance_id
}