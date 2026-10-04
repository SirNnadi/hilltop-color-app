# Cluster outputs
output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "app_irsa_role_arn" {
  description = "Service account role ARN (ECR + CloudWatch)"
  value       = module.app_irsa.iam_role_arn
}

output "lb_controller_role_arn" {
  value = module.lb_controller_irsa.iam_role_arn
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --name ${var.cluster_name}-${var.environment} --region ${var.region} --profile production"
}

# ECR output
output "ecr_app_url" {
  value = aws_ecr_repository.app.repository_url
}
