output "api_endpoint" {
  description = "API Load Balancer endpoint"
  value       = aws_lb.api.dns_name
}

output "sqs_queue_url" {
  description = "SQS Queue URL"
  value       = aws_sqs_queue.main.url
}

output "sqs_dlq_url" {
  description = "SQS DLQ URL"
  value       = aws_sqs_queue.dlq.url
}

output "dynamodb_table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.events.name
}
