terraform {
  required_version = ">= 1.0"
  
  # Uncomment and configure for remote state management
  # cloud {
  #   organization = "your-org"
  #   workspaces {
  #     name = "rust-knative-example-app"
  #   }
  # }
}


# =============================================================================
# MinIO S3-compatible Bucket Management
# =============================================================================

module "minio" {
  source = "./modules/minio"

  minio_endpoint      = var.minio_endpoint
  minio_access_key    = var.minio_access_key
  minio_secret_key    = var.minio_secret_key
  minio_use_ssl       = var.minio_use_ssl
  
  buckets = {
    "data" = {
      versioning = false
      tags = {
        environment = "development"
        managed_by  = "terraform"
      }
    }
    "data-staging" = {
      versioning = true
      tags = {
        environment = "staging"
        managed_by  = "terraform"
      }
    }
    "data-prod" = {
      versioning = true
      tags = {
        environment = "production"
        managed_by  = "terraform"
      }
    }
  }
}

