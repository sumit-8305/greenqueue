variable "visibility_timeout" {
  type    = number
  default = 900 # 15 min; must exceed your longest job
}