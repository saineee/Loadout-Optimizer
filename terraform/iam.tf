resource "aws_iam_role_policy" "ghauthpolicy" {
  name = "CDforGenshin"
  policy = jsonencode({
    Statement = [{
      Action   = ["ecr:GetAuthorizationToken"]
      Effect   = "Allow"
      Resource = ["*"]
      Sid      = "authtoken"
      }, {
      Action   = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage"]
      Effect   = "Allow"
      Resource = ["arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/genshin-app"]
      Sid      = "ecrUpload"
      }, {
      Action   = ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"]
      Effect   = "Allow"
      Resource = ["*"]
      Sid      = "ecsTaskRegistration"
      }, {
      Action   = ["ecs:UpdateService", "ecs:DescribeServices"]
      Effect   = "Allow"
      Resource = ["arn:aws:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:service/genshin-cluster/genshin-service"]
      Sid      = "ecsServiceTasks"
      }, {
      Action = ["iam:PassRole"]
      Condition = {
        StringEquals = {
          "iam:PassedToService" = "ecs-tasks.amazonaws.com"
        }
      }
      Effect   = "Allow"
      Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/genshin-task-exec-role"
      Sid      = "ecsExecRole"
    }]
    Version = "2012-10-17"
  })
  role = aws_iam_role.ghauth.name
}

resource "aws_iam_role" "ghauth" {
  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:saineee/genshin_app:ref:refs/heads/master"
        }
      }
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
      }
      Sid = "GHAuth"
    }]
    Version = "2012-10-17"
  })
  force_detach_policies = false
  name                  = "GHAuth"
}

resource "aws_iam_role" "genshin_task_exec_role" {
  name = "genshin-task-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Sid = "GenshinExec"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "genshin_attach" {
  role       = aws_iam_role.genshin_task_exec_role.id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "grab_from_ssm_genshin" {
  name = "genshin_ssm_pull"
  role = aws_iam_role.genshin_task_exec_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = "ssm:GetParameters"
      Effect   = "Allow"
      Sid      = "ssmGenshinPull"
      Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/genshin/*"
    }]
  })
}

