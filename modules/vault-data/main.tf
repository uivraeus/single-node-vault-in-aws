# Everything that must outlive a Vault node: placement (the data volume pins the
# availability zone), the unseal key and the Raft data. The node module is
# disposable and can be replaced at any time; this one should not be.
#
# In production, put this module in its own Terraform root (state), with
# prevent_destroy on the key and the volume, so that `terraform destroy` of the
# node can never reach it. The demo keeps both in one root for easy teardown.

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

# Vault data (and every snapshot of it) is useless without this key. For
# anything beyond a lab, raise the deletion window and prevent key destruction.
resource "aws_kms_key" "vault_unseal" {
  description             = "${var.name}: Vault auto-unseal"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/${var.name}-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}

# Raft storage. Lives in one availability zone; moving to another zone means a
# new (empty) volume, which the node fills from the latest snapshot.
resource "aws_ebs_volume" "vault_data" {
  availability_zone = data.aws_subnet.selected.availability_zone
  type              = "gp3"
  size              = var.data_volume_size
  encrypted         = true

  tags = {
    Name = "${var.name}-vault-data"
  }
}

# Raft snapshots. The node overwrites a single key (raft/latest.snap); versioning
# keeps the history, so a bad snapshot never replaces a good one for good, and
# the node can't delete versions. Restoring an older version is a human decision
# (scripts/vault-ops.sh restore).
resource "aws_s3_bucket" "snapshots" {
  bucket_prefix = "${var.name}-snapshots-"
  force_destroy = true # lab: `terraform destroy` removes all snapshots too
}

resource "aws_s3_bucket_versioning" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "snapshots" {
  bucket                  = aws_s3_bucket.snapshots.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Snapshots are already encrypted by Vault's barrier (and the barrier key by
# KMS); SSE-S3 is the extra layer at rest.
resource "aws_s3_bucket_server_side_encryption_configuration" "snapshots" {
  bucket = aws_s3_bucket.snapshots.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Only old versions expire. The current snapshot is kept however old it is, so
# a node that stopped taking snapshots never leaves you with none.
resource "aws_s3_bucket_lifecycle_configuration" "snapshots" {
  bucket     = aws_s3_bucket.snapshots.id
  depends_on = [aws_s3_bucket_versioning.snapshots]

  rule {
    id     = "expire-old-snapshots"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.snapshot_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}
