terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# --------------------------------------------------
# Default VPC and Subnets
# --------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# --------------------------------------------------
# ALB Security Group
# --------------------------------------------------

resource "aws_security_group" "alb" {
  name   = "nginx-alb-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    description = "Allow HTTP"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --------------------------------------------------
# ECS Security Group
# --------------------------------------------------

resource "aws_security_group" "ecs" {
  name   = "nginx-ecs-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    description     = "HTTP from ALB"
    protocol        = "tcp"
    from_port       = 80
    to_port         = 80
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --------------------------------------------------
# ECS Cluster
# --------------------------------------------------

resource "aws_ecs_cluster" "nginx" {
  name = "nginx-cluster"
}

# --------------------------------------------------
# CloudWatch Logs
# --------------------------------------------------

resource "aws_cloudwatch_log_group" "nginx" {
  name              = "/ecs/nginx"
  retention_in_days = 7
}

# --------------------------------------------------
# ECS Task Execution Role
# --------------------------------------------------

resource "aws_iam_role" "ecs_execution" {
  name = "ecs-nginx-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --------------------------------------------------
# ECS Task Definition
# --------------------------------------------------

resource "aws_ecs_task_definition" "nginx" {
  family                   = "nginx-task"
  requires_compatibilities = ["FARGATE"]

  network_mode = "awsvpc"

  cpu    = "256"
  memory = "512"

  execution_role_arn = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([
    {
      name      = "nginx"
      image     = "nginx:latest"
      essential = true

      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.nginx.name
          awslogs-region        = "us-east-1"
          awslogs-stream-prefix = "nginx"
        }
      }

      healthCheck = {
        command = [
          "CMD-SHELL",
          "curl -f http://localhost/ || exit 1"
        ]

        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }
    }
  ])
}

# --------------------------------------------------
# Application Load Balancer
# --------------------------------------------------

resource "aws_lb" "nginx" {
  name               = "nginx-alb"
  load_balancer_type = "application"

  subnets         = data.aws_subnets.default.ids
  security_groups = [aws_security_group.alb.id]
}

# --------------------------------------------------
# Target Group
# --------------------------------------------------

resource "aws_lb_target_group" "nginx" {
  name        = "nginx-targets"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"

  vpc_id = data.aws_vpc.default.id

  health_check {
    path     = "/"
    protocol = "HTTP"
    port     = "traffic-port"

    healthy_threshold   = 2
    unhealthy_threshold = 3

    interval = 30
    timeout  = 5
  }
}

# --------------------------------------------------
# ALB Listener
# --------------------------------------------------

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.nginx.arn

  port     = 80
  protocol = "HTTP"

  default_action {
    type = "forward"

    forward {
      target_group {
        arn = aws_lb_target_group.nginx.arn
      }
    }
  }
}

# --------------------------------------------------
# ECS Service
# --------------------------------------------------

resource "aws_ecs_service" "nginx" {
  name = "nginx-service"

  cluster = aws_ecs_cluster.nginx.id

  task_definition = aws_ecs_task_definition.nginx.arn

  launch_type = "FARGATE"

  # Start with 2 tasks
  desired_count = 2

  network_configuration {
    subnets = data.aws_subnets.default.ids

    security_groups = [
      aws_security_group.ecs.id
    ]

    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.nginx.arn

    container_name = "nginx"

    container_port = 80
  }

  depends_on = [
    aws_lb_listener.http,
    aws_cloudwatch_log_group.nginx
  ]
}

# --------------------------------------------------
# ECS Service Auto Scaling
# --------------------------------------------------

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 6
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.nginx.name}/${aws_ecs_service.nginx.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# --------------------------------------------------
# CPU Auto Scaling Policy
# --------------------------------------------------

resource "aws_appautoscaling_policy" "cpu" {
  name               = "nginx-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    scale_in_cooldown  = 60
    scale_out_cooldown = 60
  }
}

# --------------------------------------------------
# ALB DNS Output
# --------------------------------------------------

output "alb_dns_name" {
  description = "DNS name of the NGINX Application Load Balancer"

  value = aws_lb.nginx.dns_name
}