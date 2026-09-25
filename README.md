# Vault init secrets on AWS: Secrets Manager vs Parameter Store

Two equivalent Terraform demos. Each one runs a single Vault node on EC2 with:

- **no inbound access**: SSM Session Manager / port forwarding only,
- **AWS KMS auto-unseal**,
- an instance profile that can **write** the Vault init output (root token +
  recovery keys) to one secret and **not read it back**.

Terraform owns the secret *container*; the node fills in the value at first boot.
The root token never touches a laptop or Terraform state, and `terraform destroy`
leaves nothing behind.

| Directory | Store | Notes |
|---|---|---|
| [secrets-manager/](secrets-manager/) | `aws_secretsmanager_secret` with no version resource | Deletion can have a recovery window (`recovery_window_in_days`, default 0) |
| [parameter-store/](parameter-store/) | `aws_ssm_parameter` with a write-only placeholder (`value_wo`) | Deletion is immediate. Bumping `value_wo_version` overwrites the stored root token |

The two sets differ only in `secret.tf` (plus names in `outputs.tf`/`variables.tf`):

```bash
diff -r secrets-manager parameter-store
```

Commands for reading, writing, rotating and cleaning up are in [SNIPPETS.md](SNIPPETS.md).

## Layout (per directory)

| File | Contents |
|---|---|
| `versions.tf` | Terraform >= 1.16, AWS provider ~> 6.66, local state |
| `variables.tf` | Region, name, instance type/architecture, subnet |
| `main.tf` | Security group (egress 443 only), KMS unseal key, IAM role + instance profile, EC2 instance |
| `secret.tf` | **Store-specific**: the secret container, the node's write-only policy, the store/read commands |
| `outputs.tf` | Instance ID, secret name, ready-to-run SSM and read commands |
| `templates/user-data.sh.tftpl` | Installs Vault, configures Raft + `awskms` seal, runs an idempotent init that stores the output |

## Usage

```bash
cd secrets-manager            # or parameter-store
terraform init
terraform apply

terraform output -raw cmd_port_forward | bash     # keep running in its own terminal
eval "$(terraform output -raw cmd_root_token)"
export VAULT_ADDR=http://127.0.0.1:8200
vault status
```

Bootstrap takes a minute or two after the instance starts. Follow it with
`cmd_shell`, then `sudo tail -f /var/log/vault-bootstrap.log`.

Requirements on your machine: AWS CLI v2, the
[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html),
`jq` and the `vault` CLI.

## Demo shortcuts: don't copy into production

- Vault listens on `127.0.0.1` **without TLS**. Only acceptable because access goes through SSM on the node itself.
- Single node, local Terraform state, 7-day KMS deletion window and no `prevent_destroy` on the key, all chosen so teardown is easy.
- Default VPC with a public IP for outbound traffic. Use private subnets with NAT or VPC endpoints (ssm, ssmmessages, kms, secretsmanager) instead.
- The root token is kept (by choice, for a small trusted team). Anyone with read access to the secret, or SSM access to the node, is effectively Vault root.
