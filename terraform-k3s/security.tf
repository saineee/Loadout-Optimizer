variable "my_ip" {
  type = string
}

resource "aws_security_group" "k3s_sg" {
  name   = "${var.name_prefix}-sg"
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "k3s_sg"
  }

  ingress {
    description = "ingress from my ip via ssh"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  ingress {
    description = "ingress for kubernetes api server"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "ingress for kubelet api"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "ingress for flannel VXLAN overlay"
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    self        = true
  }

  ingress {
    description = "http ingress for app"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  egress {
    description = "egress for k3s to get k3s script, apt packages, and images"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
