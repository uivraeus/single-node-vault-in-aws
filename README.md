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

Both roots call the shared implementation in `modules/vault-node`. The store
resource, write permission, and read command are defined in each root's
`secret.tf`; compare those files to see the backend-specific differences:

```bash
diff -u secrets-manager/secret.tf parameter-store/secret.tf
```

Commands for reading, writing, rotating and cleaning up are in [SNIPPETS.md](SNIPPETS.md).

## Layout (per directory)

| File | Contents |
|---|---|
| Root `versions.tf` | Terraform >= 1.16, AWS provider ~> 6.66, local state |
| Root `variables.tf` | Region, name, instance type/architecture, subnet |
| Root `main.tf` | Calls the shared module with store-specific inputs |
| Root `secret.tf` | **Store-specific** secret container, write permission inputs, and read command |
| Root `outputs.tf` | Exposes instance ID, store name, and ready-to-run commands |
| `modules/vault-node/` | Shared network, KMS, IAM, EC2, bootstrap template, and common outputs |

## Usage

```bash
cd secrets-manager            # or parameter-store
export AWS_PROFILE=your-sso-profile
aws sso login
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
