provider "aws" {
  region = var.aws_region
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "hipaa-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"
  tags = {
    Name = "public-subnet"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}a"
  tags = {
    Name = "private-subnet"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "public_route" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_iam_role" "lambda_exec" {
  name = "lambda_exec_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_lambda_function" "secure_lambda" {
  filename         = "${path.module}/lambda/lambda.zip"
  function_name    = "hipaa-lambda"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "app.handler"
  runtime          = "python3.11"
  source_code_hash = filebase64sha256("${path.module}/lambda/lambda.zip")

  vpc_config {
    subnet_ids         = [aws_subnet.private.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }
}

resource "aws_security_group" "lambda_sg" {
  name        = "lambda-sg"
  description = "Allow Lambda VPC access"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = []
  }
}

resource "aws_apigatewayv2_api" "http_api" {
  name          = "hipaa-http-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id             = aws_apigatewayv2_api.http_api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.secure_lambda.invoke_arn
  integration_method = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "GET /"

  target = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.secure_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

resource "aws_kms_key" "s3_kms" {
  description             = "KMS key for HIPAA S3 bucket"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "hipaa_bucket" {
  bucket        = "hipaa-secure-storage-${random_id.bucket_suffix.hex}"
  force_destroy = true

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.s3_kms.arn
      }
    }
  }

  tags = {
    Name = "HIPAA Secure Storage"
  }
}

resource "aws_s3_bucket_public_access_block" "hipaa_block" {
  bucket = aws_s3_bucket.hipaa_bucket.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_cloudtrail" "main" {
  name                          = "hipaa-cloudtrail"
  s3_bucket_name                = aws_s3_bucket.hipaa_bucket.bucket
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  depends_on = [
    aws_s3_bucket_policy.hipaa_bucket_policy
  ]
}

resource "aws_guardduty_detector" "main" {
  enable = true
}

resource "aws_config_configuration_recorder" "main" {
  name     = "config-recorder"
  role_arn = aws_iam_role.config_service.arn

  recording_group {
    all_supported = true
    include_global_resource_types = true
  }

  depends_on = [aws_s3_bucket_policy.hipaa_bucket_policy]
}

resource "aws_config_delivery_channel" "main" {
  name           = "config-delivery"
  s3_bucket_name = aws_s3_bucket.hipaa_bucket.bucket

  depends_on = [
    aws_config_configuration_recorder.main,
    aws_s3_bucket_policy.hipaa_bucket_policy
  ]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true

  depends_on = [
    aws_config_configuration_recorder.main,
    aws_config_delivery_channel.main
  ]
}

resource "aws_iam_role" "config_service" {
  name = "config-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "config.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config_policy" {
  role       = aws_iam_role.config_service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSConfigRoleForOrganizations"
}

resource "aws_config_config_rule" "s3_encryption" {
  name = "s3-bucket-encryption-check"
  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "encrypted_volumes" {
  name = "encrypted-volumes-check"
  source {
    owner             = "AWS"
    source_identifier = "ENCRYPTED_VOLUMES"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "vpc_flow_logs_enabled" {
  name = "vpc-flow-logs-enabled-check"
  source {
    owner             = "AWS"
    source_identifier = "VPC_FLOW_LOGS_ENABLED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "cloudtrail_enabled" {
  name = "cloudtrail-enabled-check"

  source {
    owner             = "AWS"
    source_identifier = "CLOUD_TRAIL_ENABLED"  // Changed from CLOUDTRAIL_ENABLED to CLOUD_TRAIL_ENABLED
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_s3_bucket_policy" "hipaa_bucket_policy" {
  bucket = aws_s3_bucket.hipaa_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAccess"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action = [
          "s3:GetBucketAcl",
          "s3:PutObject"
        ]
        Resource = [
          aws_s3_bucket.hipaa_bucket.arn,
          "${aws_s3_bucket.hipaa_bucket.arn}/*"
        ]
      },
      {
        Sid    = "AWSConfigAccess"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action = [
          "s3:GetBucketAcl",
          "s3:PutObject"
        ]
        Resource = [
          aws_s3_bucket.hipaa_bucket.arn,
          "${aws_s3_bucket.hipaa_bucket.arn}/*"
        ]
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.hipaa_block]
}
