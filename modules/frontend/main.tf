resource "aws_s3_bucket" "website" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_website_configuration" "website" {
  bucket = aws_s3_bucket.website.id

  index_document {
    suffix = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "website" {
  bucket                  = aws_s3_bucket.website.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "website" {
  bucket = aws_s3_bucket.website.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadWebsiteFiles"
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:GetObject"]
      Resource  = "${aws_s3_bucket.website.arn}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.website]
}

resource "aws_s3_object" "index" {
  bucket        = aws_s3_bucket.website.id
  key           = "index.html"
  content       = var.index_html
  content_type  = "text/html; charset=utf-8"
  cache_control = "no-cache, no-store, must-revalidate"
  etag          = md5(var.index_html)
}

resource "aws_s3_object" "config" {
  bucket        = aws_s3_bucket.website.id
  key           = "config.js"
  content       = var.config_js
  content_type  = "application/javascript; charset=utf-8"
  cache_control = "no-cache, no-store, must-revalidate"
  etag          = md5(var.config_js)
}