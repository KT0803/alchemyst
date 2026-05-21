variable "project_id" {
  description = "Target Google Cloud Project ID"
  type        = string
}

variable "region" {
  description = "Primary deployment geographic region"
  type        = string
  default     = "asia-south1"
}

variable "zone" {
  description = "Primary availability zone"
  type        = string
  default     = "asia-south1-a"
}

variable "machine_type" {
  description = "Target virtual machine compute resource specification"
  type        = string
  default     = "e2-medium"
}
