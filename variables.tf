variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "environment" {
  type    = string
  default = "hackathon"
}
variable "em_api_key_parameter_name" {
  type    = string
  default = "/greenqueue/electricitymaps/api-key"
}

variable "em_zone" {
  type    = string
  default = "IN-NO"
}