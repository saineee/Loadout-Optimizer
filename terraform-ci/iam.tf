data "aws_caller_identity" "current" {}

resource "aws_iam_role" "planner_role" {
  name = "ciPlanRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GitHubOIDC"
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = "repo:saineee/Loadout-Optimizer:pull_request"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "readOnly" {
  role       = aws_iam_role.planner_role.id
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
