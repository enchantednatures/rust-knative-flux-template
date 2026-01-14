output "bucket_names" {
  description = "Created MinIO bucket names"
  value       = module.minio.bucket_names
}
