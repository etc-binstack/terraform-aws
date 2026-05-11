output "cluster_id"   { value = module.ecs_cluster.cluster_id }
output "cluster_name" { value = module.ecs_cluster.cluster_name }
output "cluster_arn"  { value = module.ecs_cluster.cluster_arn }

output "ec2_capacity_provider_name" { value = module.ecs_cluster.ec2_capacity_provider_name }
output "ec2_asg_name"               { value = module.ecs_cluster.ec2_asg_name }

output "namespace_name"   { value = module.ecs_cluster.ecs_namespace_name }
output "namespace_source" { value = module.ecs_cluster.namespace_source }
