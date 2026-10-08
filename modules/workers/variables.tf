variable "instance_profile_name" { type = string }
variable "jobs_table_name" { type = string }
variable "grid_table_name" { type = string }
variable "queue_url" { type = string }
variable "queue_name" { type = string }

variable "asg_name" {
  type    = string
  default = "greenqueue-workers" # must match the IAM module's default
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "max_size" {
  type    = number
  default = 3
}