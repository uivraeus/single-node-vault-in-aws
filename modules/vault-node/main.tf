data "aws_partition" "current" {}

resource "aws_security_group" "vault" {
  name_prefix = "${var.name}-"
  description = "Vault node: no inbound, HTTPS out for AWS APIs and package repos"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.vault.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Fixed name: Vault's AWS auth role for snapshots is bound to this ARN, and that
# binding lives in the Vault data (and every snapshot). A recreated role with the
# same name keeps working; a random suffix would break it.
resource "aws_iam_role" "vault" {
  name               = "${var.name}-vault-node"
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
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "unseal" {
  name   = "vault-auto-unseal"
  role   = aws_iam_role.vault.id
  policy = data.aws_iam_policy_document.unseal.json
}

data "aws_iam_policy_document" "store_init" {
  statement {
    sid       = "WriteVaultInitOutput"
    actions   = [var.store_write_action]
    resources = [var.store_arn]
  }

  # Guard against initialising a new Vault over an existing one. Metadata only.
  # ssm:DescribeParameters doesn't support resource-level permissions.
  statement {
    sid       = "CheckForStoredInitOutput"
    actions   = [var.store_check_action]
    resources = [var.store_check_action == "ssm:DescribeParameters" ? "*" : var.store_arn]
  }
}

resource "aws_iam_role_policy" "store_init" {
  name   = "vault-store-init"
  role   = aws_iam_role.vault.id
  policy = data.aws_iam_policy_document.store_init.json
}

data "aws_iam_policy_document" "snapshots" {
  statement {
    sid       = "WriteAndReadLatestSnapshot"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${var.snapshot_bucket_arn}/${local.snapshot_object_key}"]
  }

  statement {
    sid       = "CheckForSnapshot"
    actions   = ["s3:ListBucket"]
    resources = [var.snapshot_bucket_arn]

    condition {
      test     = "StringEquals"
      variable = "s3:prefix"
      values   = [local.snapshot_object_key]
    }
  }
}

resource "aws_iam_role_policy" "snapshots" {
  name   = "vault-snapshots"
  role   = aws_iam_role.vault.id
  policy = data.aws_iam_policy_document.snapshots.json
}

resource "aws_iam_instance_profile" "vault" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.vault.name
}

locals {
  snapshot_object_key = "raft/latest.snap"
  node_files          = "${path.module}/node-files"

  # Settings for the node scripts, sourced as shell variables. Everything
  # deployment-specific lives here, so the files in node-files/ are static.
  node_env = <<-EOT
    AWS_REGION=${var.region}
    VAULT_ADDR=http://127.0.0.1:8200
    VAULT_VERSION=${var.vault_version}
    DATA_DEVICE=${local.data_device}
    ROLE_ARN=${aws_iam_role.vault.arn}
    SNAPSHOT_BUCKET=${var.snapshot_bucket}
    SNAPSHOT_OBJECT_KEY=${local.snapshot_object_key}
    STORE_NAME=${var.store_name}
  EOT

  # Stable device path for the data volume: Nitro instances rename /dev/sdf to
  # /dev/nvmeXn1, but this udev symlink carries the volume ID.
  data_device = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${replace(var.data_volume_id, "-", "")}"

  # Every file the node needs, written by cloud-init before setup.sh runs.
  write_files = [
    { path = "/usr/local/libexec/vault-node/setup.sh", permissions = "0700", content = file("${local.node_files}/setup.sh") },
    { path = "/usr/local/bin/vault-bootstrap.sh", permissions = "0700", content = file("${local.node_files}/vault-bootstrap.sh") },
    { path = "/usr/local/bin/vault-snapshot.sh", permissions = "0700", content = file("${local.node_files}/vault-snapshot.sh") },
    { path = "/usr/local/bin/vault-configure-snapshots.sh", permissions = "0700", content = file("${local.node_files}/vault-configure-snapshots.sh") },
    { path = "/usr/local/bin/vault-restore.sh", permissions = "0700", content = file("${local.node_files}/vault-restore.sh") },
    { path = "/usr/local/bin/with-root-token", permissions = "0700", content = file("${local.node_files}/with-root-token") },
    { path = "/etc/vault-node/vault.hcl", permissions = "0644", content = file("${local.node_files}/vault.hcl") },
    { path = "/etc/systemd/system/vault.service.d/data-volume.conf", permissions = "0644", content = file("${local.node_files}/vault-data-volume.conf") },
    { path = "/etc/systemd/system/vault-snapshot.service", permissions = "0644", content = file("${local.node_files}/vault-snapshot.service") },
    { path = "/etc/systemd/system/vault-snapshot.timer", permissions = "0644", content = file("${local.node_files}/vault-snapshot.timer") },
    { path = "/etc/systemd/system/vault-snapshot-on-stop.service", permissions = "0644", content = file("${local.node_files}/vault-snapshot-on-stop.service") },

    # Generated
    { path = "/etc/vault-node/node.env", permissions = "0644", content = local.node_env },
    # vault.service's EnvironmentFile: the awskms seal reads its key and region from here.
    { path = "/etc/vault-node/vault.env", permissions = "0640", content = "AWS_REGION=${var.region}\nVAULT_AWSKMS_SEAL_KEY_ID=${var.kms_key_id}\n" },
    { path = "/etc/systemd/system/vault-snapshot.timer.d/schedule.conf", permissions = "0644", content = "[Timer]\nOnCalendar=${var.snapshot_schedule}\n" },
    { path = "/usr/local/libexec/vault-node/store-init", permissions = "0700", content = "#!/bin/bash\nset -euo pipefail\n${var.store_init_cmd}\n" },
    { path = "/usr/local/libexec/vault-node/store-check", permissions = "0700", content = "#!/bin/bash\nset -euo pipefail\n${var.store_check_cmd}\n" },
  ]

  user_data = "#cloud-config\n${yamlencode({
    write_files = local.write_files
    runcmd      = [["/usr/local/libexec/vault-node/setup.sh"]]
  })}"

  # Gzipped: cloud-init unpacks it on the node. EC2's 16 KB limit counts the stored
  # (gzipped) bytes, so this is what makes room; plain, we'd be at ~85% of the limit.
  # Terraform can't count those bytes (base64decode needs UTF-8 text), but the base64
  # length gives them: 16384 bytes are 21848 base64 characters.
  user_data_base64       = base64gzip(local.user_data)
  user_data_base64_limit = 21848
  # Its own local so that a failing precondition prints the number, not the whole blob
  user_data_base64_size = length(local.user_data_base64)
}

# Pinned on purpose: a new AMI means a new node, so OS upgrades happen when you
# change var.ami_name, not whenever Amazon publishes an image.
data "aws_ami" "selected" {
  owners = ["amazon"] # AMI names aren't unique; only accept Amazon's own image

  # AWS deprecates AL2023 AMIs ~90 days after release. Deprecated AMIs still
  # launch; without this the lookup (and so every plan) would start failing.
  include_deprecated = true

  filter {
    name   = "name"
    values = [var.ami_name]
  }
}

data "aws_ec2_instance_type" "selected" {
  instance_type = var.instance_type
}

# A reminder, not a failure: shows as a warning in plan/apply output.
check "ami_not_deprecated" {
  assert {
    condition     = data.aws_ami.selected.deprecation_time == "" || timecmp(plantimestamp(), data.aws_ami.selected.deprecation_time) < 0
    error_message = "AMI ${var.ami_name} has been deprecated since ${data.aws_ami.selected.deprecation_time}. Time to patch: set ami_name to a newer release."
  }
}

# Any change to the node's files or settings means a new node. Terraform plans the
# replacement itself (replace_triggered_by below) instead of relying on the
# provider's user_data_replace_on_change, which plans an in-place update (and then
# fails during apply) when the user data isn't known yet at plan time, e.g. when
# only the data volume is replaced.
resource "terraform_data" "user_data" {
  input = sha256(local.user_data) # a hash: changes just the same, but keeps plans readable
}

resource "aws_instance" "vault" {
  ami                         = data.aws_ami.selected.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.vault.id]
  iam_instance_profile        = aws_iam_instance_profile.vault.name
  associate_public_ip_address = var.associate_public_ip

  user_data_base64            = local.user_data_base64 # gzipped, see locals
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  maintenance_options {
    auto_recovery = "default" # restart on a healthy host after a hardware failure
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 16
  }

  tags = {
    Name = var.name
  }

  lifecycle {
    replace_triggered_by = [terraform_data.user_data]

    # Fail before EC2 sees it: at plan time when the user data is known (changes to an
    # existing node), otherwise during apply, before the instance is created. (No
    # early-warning check block: on a fresh deploy it could only say "known after apply".)
    precondition {
      condition     = local.user_data_base64_size <= local.user_data_base64_limit
      error_message = "User data is too large: ${local.user_data_base64_size} base64 characters, EC2 allows ${local.user_data_base64_limit} (16 KB gzipped). Trim node-files/ or bake files into an AMI (Packer)."
    }

    precondition {
      condition     = contains(data.aws_ec2_instance_type.selected.supported_architectures, data.aws_ami.selected.architecture)
      error_message = "Instance type ${var.instance_type} doesn't support ${data.aws_ami.selected.architecture} (the architecture of ${var.ami_name})."
    }
  }

  depends_on = [
    aws_iam_role_policy.unseal,
    aws_iam_role_policy.store_init,
    aws_iam_role_policy.snapshots,
    aws_iam_role_policy_attachment.ssm_core,
  ]
}

# Terraform attaches the volume after the instance exists; the bootstrap waits for
# it. On replacement the old instance is stopped first, so Vault shuts down
# cleanly before the volume moves. Never use create_before_destroy here: exactly
# one node may own the Raft data.
resource "aws_volume_attachment" "vault_data" {
  device_name                    = "/dev/sdf"
  volume_id                      = var.data_volume_id
  instance_id                    = aws_instance.vault.id
  stop_instance_before_detaching = true
}
