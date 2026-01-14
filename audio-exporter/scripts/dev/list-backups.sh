#!/bin/bash

# Script: List PostgreSQL backups from object storage
# Purpose: Query MinIO/S3 and list available backups with sizes
# Usage: ./list-backups.sh [endpoint] [bucket] [access-key] [secret-key]

ENDPOINT="${1:-minio.minio.svc.cluster.local:9000}"
BUCKET="${2:-postgres-backups}"
ACCESS_KEY="${3:-minioadmin}"
SECRET_KEY="${4:-minioadmin}"

echo "Listing backups from: $ENDPOINT/$BUCKET"
echo ""

# Check if AWS CLI is available
if ! command -v aws &> /dev/null; then
    echo "AWS CLI not found. Installing..."
    # Instructions for installing AWS CLI
    echo "Please install AWS CLI: https://aws.amazon.com/cli/"
    exit 1
fi

# Configure AWS CLI for MinIO (if not AWS S3)
if [[ "$ENDPOINT" != *"amazonaws.com"* ]]; then
    echo "Configuring for MinIO endpoint: $ENDPOINT"
    
    # List backups with size
    aws --endpoint-url="http://$ENDPOINT" \
        s3 ls "s3://$BUCKET/" \
        --recursive \
        --human-readable \
        --summarize \
        --access-key "$ACCESS_KEY" \
        --secret-key "$SECRET_KEY"
else
    # AWS S3
    echo "Listing from AWS S3..."
    
    aws s3 ls "s3://$BUCKET/" \
        --recursive \
        --human-readable \
        --summarize
fi

echo ""
echo "For more details, use:"
echo "  aws s3 ls s3://$BUCKET/ --recursive"
echo ""
echo "To download a backup:"
echo "  aws s3 sync s3://$BUCKET/dev/ ./postgres-backup-dev/"
