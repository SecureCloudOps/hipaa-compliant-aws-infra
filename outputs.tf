output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "api_gateway_endpoint" {
  value = aws_apigatewayv2_api.http_api.api_endpoint
}

output "s3_bucket_name" {
  value = aws_s3_bucket.hipaa_bucket.bucket
}
