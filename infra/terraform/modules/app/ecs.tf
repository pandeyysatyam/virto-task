# ECS on Fargate: no servers to patch, each task gets its own ENI in the
# private app subnets. The frontend finds the platform through Cloud Map
# private DNS (platform.<name>.local). Plain DNS is used instead of Service
# Connect because nginx resolves upstream names with its own resolver and
# does not read the /etc/hosts entries that Service Connect injects.

locals {
  secret_db    = var.secret_arns.db
  secret_cache = var.secret_arns.cache

  platform_env = [
    { name = "ASPNETCORE_ENVIRONMENT", value = "Production" },
    { name = "DatabaseProvider", value = "PostgreSql" },
    # TLS ends at the ALB, traffic ALB -> task is HTTP inside the VPC
    { name = "VirtoCommerce__AllowInsecureHttp", value = "true" },
    { name = "ASPNETCORE_FORWARDEDHEADERS_ENABLED", value = "true" },
    { name = "VirtoCommerce__Hangfire__JobStorageType", value = "Database" },
    { name = "Search__Provider", value = var.opensearch_endpoint == null ? "Lucene" : "OpenSearch" },
    { name = "Search__OpenSearch__Server", value = coalesce(var.opensearch_endpoint, "none") },
    { name = "Search__OpenSearch__User", value = "virto" },
    { name = "Search__Scope", value = var.name },
    { name = "Assets__Provider", value = "FileSystem" },
    { name = "Assets__FileSystem__RootPath", value = "~/assets" },
    { name = "Assets__FileSystem__PublicUrl", value = "https://${var.admin_domain}/assets/" },
    { name = "Content__FileSystem__PublicUrl", value = "https://${var.admin_domain}/cms-content/" },
    { name = "VirtoCommerce__PlatformUI__EnvironmentBanner__Name", value = var.environment },
  ]
}

resource "aws_ecs_cluster" "this" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = "enhanced"
  }
}

resource "aws_service_discovery_private_dns_namespace" "this" {
  name = "${var.name}.local"
  vpc  = var.vpc_id
}

resource "aws_service_discovery_service" "platform" {
  name = "platform"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.this.id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  health_check_custom_config {}
}

resource "aws_ecs_task_definition" "platform" {
  family                   = "${var.name}-platform"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.platform_cpu
  memory                   = var.platform_memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.platform_task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64" # the Virto image is published for amd64 only
  }

  container_definitions = jsonencode([{
    name         = "platform"
    image        = var.platform_image
    essential    = true
    portMappings = [{ name = "platform", containerPort = 8080, protocol = "tcp" }]
    environment  = local.platform_env
    secrets = [
      { name = "ConnectionStrings__VirtoCommerce", valueFrom = "${local.secret_db}:connection_string::" },
      { name = "ConnectionStrings__RedisConnectionString", valueFrom = "${local.secret_cache}:connection_string::" },
      { name = "Search__OpenSearch__Password", valueFrom = "${var.secret_arns.search}:password::" },
    ]
    mountPoints = var.efs_file_system_id == null ? [] : [
      { sourceVolume = "assets", containerPath = "/opt/virtocommerce/platform/wwwroot/assets", readOnly = false },
    ]
    healthCheck = {
      command     = ["CMD-SHELL", "curl -fsS http://localhost:8080/health || exit 1"]
      interval    = 30
      timeout     = 10
      retries     = 5
      startPeriod = 300
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = var.log_group_names.platform
        awslogs-region        = var.region
        awslogs-stream-prefix = "platform"
      }
    }
    readonlyRootFilesystem = false
  }])

  dynamic "volume" {
    for_each = var.efs_file_system_id == null ? [] : [1]
    content {
      name = "assets"
      efs_volume_configuration {
        file_system_id     = var.efs_file_system_id
        transit_encryption = "ENABLED"
        authorization_config {
          access_point_id = var.efs_access_point_id
          iam             = "ENABLED"
        }
      }
    }
  }
}

resource "aws_ecs_task_definition" "frontend" {
  family                   = "${var.name}-frontend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.frontend_task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name         = "frontend"
    image        = var.frontend_image
    essential    = true
    portMappings = [{ name = "frontend", containerPort = 8080, protocol = "tcp" }]
    environment = [
      { name = "PLATFORM_UPSTREAM", value = "platform.${var.name}.local:8080" },
      # Amazon provided DNS, reachable from every task in the VPC
      { name = "NGINX_RESOLVER", value = "169.254.169.253" },
    ]
    healthCheck = {
      command     = ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8080/nginx-health || exit 1"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 20
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = var.log_group_names.frontend
        awslogs-region        = var.region
        awslogs-stream-prefix = "frontend"
      }
    }
  }])
}

resource "aws_ecs_service" "platform" {
  name                              = "platform"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.platform.arn
  desired_count                     = var.platform_min_tasks
  launch_type                       = "FARGATE"
  platform_version                  = "LATEST"
  health_check_grace_period_seconds = 600
  enable_execute_command            = true
  propagate_tags                    = "SERVICE"

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [var.security_group_ids.platform]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.platform.arn
    container_name   = "platform"
    container_port   = 8080
  }

  service_registries {
    registry_arn = aws_service_discovery_service.platform.arn
  }

  # A failed deployment rolls back to the last working task definition by itself
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  lifecycle {
    ignore_changes = [desired_count] # owned by autoscaling
  }

  depends_on = [aws_lb_listener.https]
}

resource "aws_ecs_service" "frontend" {
  name                              = "frontend"
  cluster                           = aws_ecs_cluster.this.id
  task_definition                   = aws_ecs_task_definition.frontend.arn
  desired_count                     = var.frontend_min_tasks
  launch_type                       = "FARGATE"
  platform_version                  = "LATEST"
  health_check_grace_period_seconds = 60
  propagate_tags                    = "SERVICE"

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [var.security_group_ids.frontend]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend.arn
    container_name   = "frontend"
    container_port   = 8080
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_listener.https]
}

# Autoscaling on CPU. Platform scaling needs OpenSearch + Valkey (shared
# index and cache), which is why Lucene is local only.
resource "aws_appautoscaling_target" "platform" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.platform.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.platform_min_tasks
  max_capacity       = var.platform_max_tasks
}

resource "aws_appautoscaling_policy" "platform_cpu" {
  name               = "${var.name}-platform-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.platform.service_namespace
  resource_id        = aws_appautoscaling_target.platform.resource_id
  scalable_dimension = aws_appautoscaling_target.platform.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 120
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_target" "frontend" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.frontend.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.frontend_min_tasks
  max_capacity       = var.frontend_max_tasks
}

resource "aws_appautoscaling_policy" "frontend_cpu" {
  name               = "${var.name}-frontend-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.frontend.service_namespace
  resource_id        = aws_appautoscaling_target.frontend.resource_id
  scalable_dimension = aws_appautoscaling_target.frontend.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
