
# ─────────────────────────────────────────────────────────────────────────────
# Remote backend — state stored in S3, locking via DynamoDB
# (Provisioned by the bootstrap/ folder)
# ─────────────────────────────────────────────────────────────────────────────
terraform {
  backend "s3" {
    bucket         = "tfstate-weather-pipeline-iq88y9p0"
    key            = "infra/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tflock-weather-pipeline-iq88y9p0"
    encrypt        = true
  }
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# --------------------------------------------------------------------
# Random suffix used for all resource names
# --------------------------------------------------------------------
resource "random_string" "suffix" {
  length  = 16
  lower   = true
  upper   = false
  numeric = true
  special = false
}

# --------------------------------------------------------------------
# S3 Buckets
# --------------------------------------------------------------------
resource "aws_s3_bucket" "scripts" {
  bucket        = "s3-scripts-${random_string.suffix.result}"
  force_destroy = true
}

resource "aws_s3_bucket" "data_lake" {
  bucket        = "s3-data-lake-${random_string.suffix.result}"
  force_destroy = true
}

# --------------------------------------------------------------------
# TEST Lambda Layer (common for both functions)
# --------------------------------------------------------------------
resource "local_file" "layer_common_code" {
  filename = "${path.module}/layer_common.py"
  content  = <<-EOF
def helper():
    return "Hello from TEST layer"
EOF
}

data "archive_file" "layer_common_zip" {
  type        = "zip"
  source_file = local_file.layer_common_code.filename
  output_path = "${path.module}/dist/common_layer.zip"
}

resource "aws_s3_object" "layer_common_zip" {
  bucket = aws_s3_bucket.scripts.id
  key    = "layer/common_layer.zip"
  source = data.archive_file.layer_common_zip.output_path
  etag   = data.archive_file.layer_common_zip.output_md5
}

resource "aws_lambda_layer_version" "common" {
  s3_bucket           = aws_s3_bucket.scripts.id
  s3_key              = aws_s3_object.layer_common_zip.key
  layer_name          = "common-layer-${random_string.suffix.result}"
  compatible_runtimes = ["python3.9"]
  source_code_hash    = data.archive_file.layer_common_zip.output_base64sha256
  depends_on          = [aws_s3_object.layer_common_zip]
}

# --------------------------------------------------------------------
# IAM Role for Lambdas (shared)
# --------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "lambda-role-${random_string.suffix.result}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "lambda_service" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_admin" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# --------------------------------------------------------------------
# Lambda Function: fetch
# --------------------------------------------------------------------
resource "local_file" "lambda_fetch_code" {
  filename = "${path.module}/src/fetch_lambda.py"
  content  = <<-EOF
def lambda_handler(event, context):
    import json, boto3
    sqs = boto3.client('sqs')
    queue_url = '${aws_sqs_queue.payload_queue.id}'
    message = {"msg": "test payload"}
    sqs.send_message(QueueUrl=queue_url, MessageBody=json.dumps(message))
    return {"statusCode": 200}
EOF
}

data "archive_file" "lambda_fetch_zip" {
  type        = "zip"
  source_file = local_file.lambda_fetch_code.filename
  output_path = "${path.module}/dist/fetch_lambda.zip"
}

resource "aws_s3_object" "lambda_fetch_zip" {
  bucket = aws_s3_bucket.scripts.id
  key    = "lambda/fetch.zip"
  source = data.archive_file.lambda_fetch_zip.output_path
  etag   = data.archive_file.lambda_fetch_zip.output_md5
}

resource "aws_lambda_function" "fetch" {
  function_name    = "lambda-fetch-${random_string.suffix.result}"
  s3_bucket        = aws_s3_bucket.scripts.id
  s3_key           = aws_s3_object.lambda_fetch_zip.key
  source_code_hash = data.archive_file.lambda_fetch_zip.output_base64sha256
  handler          = "fetch_lambda.lambda_handler"
  runtime          = "python3.9"
  role             = aws_iam_role.lambda_role.arn
  layers           = [aws_lambda_layer_version.common.arn]
  depends_on       = [aws_s3_object.lambda_fetch_zip, aws_lambda_layer_version.common]
}

# --------------------------------------------------------------------
# Lambda Function: process
# --------------------------------------------------------------------
resource "local_file" "lambda_process_code" {
  filename = "${path.module}/src/process_lambda.py"
  content  = <<-EOF
def lambda_handler(event, context):
    import json, boto3, datetime
    s3 = boto3.client('s3')
    for record in event['Records']:
        payload = json.loads(record['body'])
        # simple validation/enrichment
        payload['validated'] = True
        payload['enriched_at'] = datetime.datetime.utcnow().isoformat()
        # partition by date/hour
        now = datetime.datetime.utcnow()
        prefix = f"{now:%Y/%m/%d/%H}"
        key = f"{prefix}/record_{record['messageId']}.json"
        s3.put_object(Bucket='${aws_s3_bucket.data_lake.bucket}', Key=key,
                      Body=json.dumps(payload).encode())
    return {"statusCode": 200}
EOF
}

data "archive_file" "lambda_process_zip" {
  type        = "zip"
  source_file = local_file.lambda_process_code.filename
  output_path = "${path.module}/dist/process_lambda.zip"
}

resource "aws_s3_object" "lambda_process_zip" {
  bucket = aws_s3_bucket.scripts.id
  key    = "lambda/process.zip"
  source = data.archive_file.lambda_process_zip.output_path
  etag   = data.archive_file.lambda_process_zip.output_md5
}

resource "aws_lambda_function" "process" {
  function_name    = "lambda-process-${random_string.suffix.result}"
  s3_bucket        = aws_s3_bucket.scripts.id
  s3_key           = aws_s3_object.lambda_process_zip.key
  source_code_hash = data.archive_file.lambda_process_zip.output_base64sha256
  handler          = "process_lambda.lambda_handler"
  runtime          = "python3.9"
  role             = aws_iam_role.lambda_role.arn
  layers           = [aws_lambda_layer_version.common.arn]
  depends_on       = [aws_s3_object.lambda_process_zip, aws_lambda_layer_version.common]
}

# --------------------------------------------------------------------
# SQS Queue
# --------------------------------------------------------------------
resource "aws_sqs_queue" "payload_queue" {
  name = "sqs-queue-${random_string.suffix.result}"
}

# Event source mapping: process Lambda reads from SQS
resource "aws_lambda_event_source_mapping" "process_sqs" {
  event_source_arn = aws_sqs_queue.payload_queue.arn
  function_name    = aws_lambda_function.process.arn
  batch_size       = 10
  enabled          = true
}

# --------------------------------------------------------------------
# EventBridge Rule to trigger fetch Lambda on schedule
# --------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "schedule_fetch" {
  name                = "eventbridge-schedule-${random_string.suffix.result}"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "fetch_target" {
  rule      = aws_cloudwatch_event_rule.schedule_fetch.name
  arn       = aws_lambda_function.fetch.arn
  target_id = "fetchLambdaTarget"
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fetch.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule_fetch.arn
}
