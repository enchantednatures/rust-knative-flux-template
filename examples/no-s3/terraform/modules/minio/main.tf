terraform {
  required_version = ">= 1.0"
  required_providers {
    minio = {
      source  = "aminueza/minio"
      version = "~> 2.0"
    }
  }
}

variable "minio_endpoint" {
  description = "MinIO S3-compatible endpoint (e.g., http://minio:9000)"
  type        = string
}

variable "minio_access_key" {
  description = "MinIO root access key"
  type        = string
  sensitive   = true
}

variable "minio_secret_key" {
  description = "MinIO root secret key"
  type        = string
  sensitive   = true
}

variable "minio_use_ssl" {
  description = "Whether to use SSL for MinIO connection"
  type        = bool
  default     = false
}

variable "buckets" {
  description = "Map of bucket names to their configuration"
  type = map(object({
    versioning = optional(bool, false)
    tags       = optional(map(string), {})
  }))
}

provider "minio" {
  minio_server   = var.minio_endpoint
  minio_user     = var.minio_access_key
  minio_password = var.minio_secret_key
  minio_use_ssl  = var.minio_use_ssl
}

resource "minio_s3_bucket" "this" {
  for_each = var.buckets

  bucket = each.key

  # Optional: Enable versioning
  # versioning = each.value.versioning
}

# Tag buckets if needed
resource "minio_s3_bucket_tagging" "this" {
  for_each = { for k, v in var.buckets : k => v if length(v.tags) > 0 }

  bucket = minio_s3_bucket.this[each.key].id
  tags   = each.value.tags
}

output "bucket_names" {
  description = "Created bucket names"
  value       = [for b in minio_s3_bucket.this : b.id]
}
