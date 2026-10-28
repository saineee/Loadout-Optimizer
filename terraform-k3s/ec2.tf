data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

resource "aws_key_pair" "ssh_access" {
  key_name   = "${var.name_prefix}-ssh"
  public_key = file("${path.module}/k3s_ssh.pub")
}

resource "aws_instance" "server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  key_name               = aws_key_pair.ssh_access.id
  vpc_security_group_ids = [aws_security_group.k3s_sg.id]

  tags = {
    Name = "${var.name_prefix}-server"
  }
}

resource "aws_instance" "agent" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[1].id
  key_name               = aws_key_pair.ssh_access.id
  vpc_security_group_ids = [aws_security_group.k3s_sg.id]

  tags = {
    Name = "${var.name_prefix}-agent"
  }
}

output "agent-private-ip" {
  value = aws_instance.agent.private_ip
}

output "agent-public-ip" {
  value = aws_instance.agent.public_ip
}

output "server-private-ip" {
  value = aws_instance.server.private_ip
}

output "server-public-ip" {
  value = aws_instance.server.public_ip
}
