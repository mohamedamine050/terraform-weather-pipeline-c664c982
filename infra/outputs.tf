output "scripts_bucket_name" {
  value = aws_s3_bucket.scripts.id
}

output "data_lake_bucket_name" {
  value = aws_s3_bucket.data_lake.id
}

output "lambda_fetch_name" {
  value = aws_lambda_function.fetch.function_name
}

output "lambda_fetch_arn" {
  value = aws_lambda_function.fetch.arn
}

output "lambda_process_name" {
  value = aws_lambda_function.process.function_name
}

output "lambda_process_arn" {
  value = aws_lambda_function.process.arn
}

output "eventbridge_rule_name" {
  value = aws_cloudwatch_event_rule.schedule_fetch.name
}

output "eventbridge_rule_arn" {
  value = aws_cloudwatch_event_rule.schedule_fetch.arn
}

output "sqs_queue_url" {
  value = aws_sqs_queue.payload_queue.id
}

output "sqs_queue_arn" {
  value = aws_sqs_queue.payload_queue.arn
}

output "glue_test_script_s3_uri_fetch" {
  value = "s3://${aws_s3_bucket.scripts.bucket}/${aws_s3_object.lambda_fetch_zip.key}"
}

output "glue_test_script_s3_uri_process" {
  value = "s3://${aws_s3_bucket.scripts.bucket}/${aws_s3_object.lambda_process_zip.key}"
}

output "layer_test_zip_s3_uri" {
  value = "s3://${aws_s3_bucket.scripts.bucket}/${aws_s3_object.layer_common_zip.key}"
}
