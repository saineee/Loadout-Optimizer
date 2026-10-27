terraform {
  backend "s3" {
    bucket       = "genshin-tfstate-330866750121"
    key          = "genshin/k3s/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

provider "aws" {
  region              = var.region
  allowed_account_ids = ["330866750121"]
}

