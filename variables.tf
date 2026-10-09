variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "environment" {
  type    = string
  default = "hackathon"
}
variable "em_api_key" {
  type      = string
  sensitive = true
}

variable "em_zone" {
  type    = string
  default = "IN-NO"
}