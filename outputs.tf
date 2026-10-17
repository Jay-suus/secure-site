# Values Terraform prints after `terraform apply`.

output "website_url" {
  description = "Open this in your browser once the distribution finishes deploying."
  value       = "https://${aws_cloudfront_distribution.site.domain_name}"
}

output "bucket_name" {
  description = "The private bucket holding the site files."
  value       = aws_s3_bucket.site.id
}

output "distribution_id" {
  description = "CloudFront distribution ID (handy for cache invalidations)."
  value       = aws_cloudfront_distribution.site.id
}
