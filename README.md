# single-node-vault-in-aws

A single [HashiCorp Vault](https://www.vaultproject.io/) node on AWS, where Terraform is the single source of truth: everything the node runs, from the AMI and Vault version to its boot scripts, is part of the Terraform code.

The node is disposable. Upgrades, OS patches, resizes and moves to another availability zone all replace it, because everything worth keeping lives outside it.

**What you get**

- **No inbound access:** everything goes through SSM Session Manager.
- **KMS auto-unseal.**
- **Init output stays off the node and off disk:** the root token and recovery keys go straight from `vault operator init` into Secrets Manager or Parameter Store. The node can write them but not read them back, and they never land on disk or in Terraform state.
- **Data that outlives the node:** Raft storage on its own EBS volume, plus Raft snapshots to a versioned S3 bucket, taken hourly and at every clean shutdown. A new node with an empty volume restores the latest snapshot by itself.
- **Maintenance by variables:** `vault_version`, `ami_name` and `instance_type` each lead to a new node with the same data. See [MAINTENANCE.md](MAINTENANCE.md).
- **`scripts/vault-ops.sh`** for everything after `terraform apply`: status, logs, a shell, Vault commands on the node, snapshots, rollbacks, and a snapshot-guarded `apply`.
- **End-to-end tests** against real AWS resources (`tests/e2e.sh`), with results in [tests/LOG.md](tests/LOG.md).

A lab and reference setup rather than a production deployment: see [Demo shortcuts](#demo-shortcuts-dont-copy-into-production).

## Where the init output goes

Two equivalent Terraform roots, differing only in where the init output is stored. In both, Terraform owns the secret *container* and the node fills in the value at first boot, so `terraform destroy` leaves nothing behind. Later, `scripts/vault-ops.sh` reads the root token into memory, with your own AWS credentials, only to mint short-lived tokens.

| Directory | Store | Notes |
|---|---|---|
| [secrets-manager/](secrets-manager/) | `aws_secretsmanager_secret` with no version resource | Deletion can have a recovery window (`recovery_window_in_days`, default 0) |
| [parameter-store/](parameter-store/) | `aws_ssm_parameter` with a write-only placeholder (`value_wo`) | Deletion is immediate. Bumping `value_wo_version` overwrites the stored root token |

Both roots call the shared modules: `modules/vault-data` (unseal key, data volume, snapshot bucket) and `modules/vault-node` (the disposable node). The store resource, write permission, and read command are defined in each root's `secret.tf`; compare those files to see the backend-specific differences:

```bash
diff -u secrets-manager/secret.tf parameter-store/secret.tf
```

Commands for reading, writing, rotating and cleaning up are in [SNIPPETS.md](SNIPPETS.md). Upgrades, resizing, snapshots and recovery are in [MAINTENANCE.md](MAINTENANCE.md). Non-obvious AWS, SSM, Terraform and Vault behaviour we ran into along the way is in [LESSONS.md](LESSONS.md).

## Layout

| File | Contents |
|---|---|
| Root `versions.tf` | Terraform >= 1.16, AWS provider ~> 6.66, local state |
| Root `variables.tf` | Region, name, instance type, subnet, Vault version, AMI name |
| Root `main.tf` | Calls the two shared modules with store-specific inputs |
| Root `secret.tf` | **Store-specific** secret container, write/check permission inputs, and read command |
| Root `outputs.tf` | Instance ID, store name, KMS key, data volume, snapshot bucket, and the store's read command (used by `vault-ops.sh`) |
| `modules/vault-data/` | Long-lived: KMS unseal key, EBS data volume (pins the AZ), versioned S3 snapshot bucket |
| `vault-config/` | Vault's own configuration with the `vault` provider: for now a KV v2 engine at `secret/` |
| `modules/vault-node/` | Disposable: security group, IAM, EC2, volume attachment, and `node-files/` (setup script, bootstrap, snapshot script, systemd units, Vault config) |
| `scripts/vault-ops.sh` | Entry point after `terraform apply`: status, logs, shell, port forward, Vault commands on the node, snapshots, restore, snapshot-guarded `terraform apply`, Terraform for `vault-config/` |
| `tests/` | End-to-end tests against real AWS (`e2e.sh`) and their results (`LOG.md`) |
| `LESSONS.md` | Non-obvious behaviour of AWS, SSM, Terraform and Vault, and where the repo handles it |

## Usage

```bash
cd secrets-manager            # or parameter-store
export AWS_PROFILE=your-sso-profile
aws sso login
terraform init
terraform apply

../scripts/vault-ops.sh logs -f        # watch the bootstrap (a minute or two), Ctrl-C when done
../scripts/vault-ops.sh wait-ready     # or just wait for it
../scripts/vault-ops.sh status
../scripts/vault-ops.sh vault status   # the node's vault CLI, as root
```

`scripts/vault-ops.sh` (run it without arguments for the full list) is the entry point for everything after `terraform apply`: a shell on the node (`shell`), a port forward for your own tools (`port-forward`), snapshots, restores and upgrades (see [MAINTENANCE.md](MAINTENANCE.md)).

## Configuring Vault with Terraform

[vault-config/](vault-config/) is a separate Terraform root for what lives *inside* Vault: secrets engines, policies, auth methods. For now it has a KV v2 engine at `secret/`. It never holds secret values: Terraform creates the mounts, people and apps write the data.

`vault-ops.sh tf` runs it: it opens a port forward for the duration of the run and gives Terraform a short-lived root token (15 minutes, revoked when Terraform exits), read with your own AWS credentials like every other root-token use in this repo. Run it from the infrastructure root, whose outputs locate the node:

```bash
cd secrets-manager            # or parameter-store
../scripts/vault-ops.sh tf ../vault-config init
../scripts/vault-ops.sh tf ../vault-config apply
```

- **Scope:** the `aws/` auth mount and the `raft-snapshot` role and policy belong to the node bootstrap (`vault-configure-snapshots.sh`); `vault-config/` doesn't manage them.
- **State:** Vault's configuration lives in Vault's data, so it survives node replacements and restores along with everything else. After `terraform destroy` of the infrastructure, `vault-config/`'s state describes a Vault that no longer exists: delete it (`rm vault-config/terraform.tfstate*`) before starting over.

## Requirements

On your machine: Terraform, AWS CLI v2, the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html), `jq` and `curl`. No `vault` CLI is needed: `scripts/vault-ops.sh vault ...` runs the node's own. The script checks these (and your AWS credentials) before it does anything.

## Demo shortcuts: don't copy into production

- Vault listens on `127.0.0.1` **without TLS**. Only acceptable because access goes through SSM on the node itself.
- Single node, local Terraform state, 7-day KMS deletion window, no `prevent_destroy` on the key or the data volume, and `force_destroy` on the snapshot bucket, all chosen so teardown is easy. `terraform destroy` deletes Vault's data *and* every snapshot. See [MAINTENANCE.md](MAINTENANCE.md#production-notes).
- Default VPC with a public IP for outbound traffic. Use private subnets with NAT or VPC endpoints (ssm, ssmmessages, kms, secretsmanager, sts, and an s3 gateway endpoint for the snapshots) instead.
- The root token is kept (by choice, for a small trusted team). Anyone with read access to the secret, or SSM access to the node, is effectively Vault root.

## License

[MIT](LICENSE)
