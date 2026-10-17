# Phase 1: a static website stored in a PRIVATE S3 bucket and served to the
# internet only through CloudFront.
#
#   Visitor --HTTPS--> CloudFront --signed request (OAC)--> private S3 bucket
#
# The bucket is never public. CloudFront proves who it is with Origin Access
# Control (OAC), and the bucket policy only accepts requests from this one
# CloudFront distribution.

# ---------------------------------------------------------------------------
# S3 bucket (where the website files live)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "site" {
  # Bucket names are global across all of AWS, so let Terraform add a
  # random suffix to keep it unique.
  bucket_prefix = "${var.project}-"

  # LAB ONLY: lets `terraform destroy` delete the bucket even when it still
  # holds files. In production you'd leave this false to prevent accidents.
  force_destroy = true
}

# Block every form of public access, at the bucket level. This is the
# single most important S3 setting: most real-world S3 leaks are buckets
# that were accidentally made public.
resource "aws_s3_bucket_public_access_block" "site" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Disable ACLs entirely. Access is controlled only by policies, which are
# easier to audit than per-object ACLs.
resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Encrypt everything at rest. SSE-S3 (AES-256) is free and automatic.
# Phase 2 idea: switch to a customer-managed KMS key and compare.
resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Keep old versions of files, so an accidental overwrite or delete
# (or ransomware-style tampering) can be rolled back.
resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ---------------------------------------------------------------------------
# Website files
# ---------------------------------------------------------------------------

locals {
  site_dir = "${path.module}/site"

  # S3 needs the right Content-Type or browsers will download files instead
  # of displaying them.
  mime_types = {
    html = "text/html"
    css  = "text/css"
    js   = "application/javascript"
    png  = "image/png"
    jpg  = "image/jpeg"
    svg  = "image/svg+xml"
    ico  = "image/x-icon"
  }
}

# Uploads every file in the site/ folder. Edit a file, run `terraform apply`,
# and only the changed file is re-uploaded (etag tracks the file's hash).
resource "aws_s3_object" "site_files" {
  for_each = fileset(local.site_dir, "**")

  bucket       = aws_s3_bucket.site.id
  key          = each.value
  source       = "${local.site_dir}/${each.value}"
  etag         = filemd5("${local.site_dir}/${each.value}")
  content_type = lookup(local.mime_types, reverse(split(".", each.value))[0], "application/octet-stream")
}

# ---------------------------------------------------------------------------
# CloudFront (the public front door)
# ---------------------------------------------------------------------------

# Origin Access Control: CloudFront signs every request it sends to S3, so
# the bucket can verify the request really came from CloudFront.
resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.project}-oac"
  description                       = "Lets CloudFront read the private site bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# AWS-managed policies, looked up by name.
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

# Adds browser security headers (HSTS, X-Frame-Options, X-Content-Type-Options,
# Referrer-Policy, etc.) to every response.
data "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "Managed-SecurityHeadersPolicy"
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  comment             = "${var.project} static site"
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # cheapest: North America + Europe edges only

  origin {
    origin_id                = "s3-site"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id           = "s3-site"
    viewer_protocol_policy     = "redirect-to-https" # never serve plain HTTP
    allowed_methods            = ["GET", "HEAD"]     # read-only site
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
  }

  # S3 returns 403 (not 404) for missing files when the caller can't list the
  # bucket. Show a friendly 404 page instead of leaking an S3 error.
  custom_error_response {
    error_code         = 403
    response_code      = 404
    response_page_path = "/404.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Uses the free *.cloudfront.net certificate. Note for Phase 3: scanners
  # will flag the minimum TLS version here; fixing it requires a custom
  # domain + ACM certificate, which is a good stretch goal.
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# ---------------------------------------------------------------------------
# Bucket policy: the ONLY way in is through this CloudFront distribution
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "site_bucket" {
  # Allow CloudFront to read objects, but only on behalf of OUR distribution.
  # The SourceArn condition stops any other CloudFront distribution (including
  # someone else's) from using this bucket.
  statement {
    sid       = "AllowCloudFrontReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }

  # Refuse any request that isn't encrypted in transit.
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.site.arn,
      "${aws_s3_bucket.site.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site_bucket.json

  # The public access block must exist first, or AWS may briefly evaluate
  # the policy without it.
  depends_on = [aws_s3_bucket_public_access_block.site]
}
