# Shared by both demos: one Vault node on EC2, reachable only through SSM,
# with AWS KMS auto-unseal. Everything store-specific lives in secret.tf.

data "aws_partition" "current" {}

# --- Network: no inbound access at all, SSM is the only way in ---------------

data "aws_vpc" "default" {
  count   = var.subnet_id == null ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = var.subnet_id == null ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
}

data "aws_subnet" "selected" {
  id = coalesce(var.subnet_id, try(sort(data.aws_subnets.default[0].ids)[0], null))
}

resource "aws_security_group" "vault" {
  name_prefix = "${var.name}-"
  description = "Vault node: no inbound, HTTPS out for SSM, KMS and package repos"
  vpc_id      = data.aws_subnet.selected.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.vault.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# --- KMS key for auto-unseal ---------------------------------------------------
# Losing this key means losing Vault's data. For anything beyond a lab, raise the
# deletion window and add lifecycle { prevent_destroy = true }.

resource "aws_kms_key" "vault_unseal" {
  description             = "${var.name}: Vault auto-unseal"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/${var.name}-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}

# --- Instance role -------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vault" {
  name_prefix        = "${var.name}-"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.vault.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "unseal" {
  statement {
    sid       = "VaultAutoUnseal"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.vault_unseal.arn]
  }
}

resource "aws_iam_role_policy" "unseal" {
  name   = "vault-auto-unseal"
  role   = aws_iam_role.vault.id
  policy = data.aws_iam_policy_document.unseal.json
}

resource "aws_iam_instance_profile" "vault" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.vault.name
}

# --- Vault node ----------------------------------------------------------------

locals {
  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    region         = var.region
    kms_key_id     = aws_kms_key.vault_unseal.key_id
    store_name     = local.store_name     # from secret.tf
    store_init_cmd = local.store_init_cmd # from secret.tf
  })
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-${var.architecture}"]
  }
}

resource "aws_instance" "vault" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.selected.id
  vpc_security_group_ids      = [aws_security_group.vault.id]
  iam_instance_profile        = aws_iam_instance_profile.vault.name
  associate_public_ip_address = var.associate_public_ip

  user_data                   = local.user_data
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 16
  }

  tags = {
    Name = var.name
  }

  # A new AMI must not replace the node: a new root volume means a new, empty
  # Vault whose init output would overwrite the stored one.
  lifecycle {
    ignore_changes = [ami]
  }

  # Make sure the role can write the init output before bootstrap runs.
  depends_on = [
    aws_iam_role_policy.unseal,
    aws_iam_role_policy.store_init,
    aws_iam_role_policy_attachment.ssm_core,
  ]
}
