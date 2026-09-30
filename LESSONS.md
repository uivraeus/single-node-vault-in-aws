# Lessons learnt

Non-obvious behaviour of AWS, SSM, Terraform and Vault that we ran into while building and testing this repo. Each entry says what happens and where the repo deals with it.

## SSM Session Manager

- **`aws ssm start-session` doesn't return the remote command's exit code.** The session always ends with exit code 0. `session()` in [scripts/vault-ops.sh](scripts/vault-ops.sh) prints a marker line with the exit code on the node and parses it locally.
- **Sessions run as `ssm-user`, not root**, and the `AWS-StartNonInteractiveCommand` document doesn't run the command through a shell: `;`, pipes and quotes nested inside other quotes don't work as you'd expect. `session()` base64-encodes the command and pipes it into `sudo bash`.
- **The Session Manager plugin ends the session when its own stdin closes.** Run from a script with stdin at `/dev/null`, the command never runs. `session()` keeps stdin open with a background `sleep` for the length of the session.
- **Non-interactive sessions deliver output at the end, not as it comes.** `tail -f` over one shows nothing. `vault-ops.sh logs -f` uses `AWS-StartInteractiveCommand` instead, which has a terminal on the node, so output streams and Ctrl-C reaches `tail`.
- **The `aws` CLI runs the plugin as a child process.** Killing the CLI leaves the plugin running, and with it the port forward and any pipes it inherited, so `... 2>&1 | jq` hangs. `root_wrap()` stops the child too.
- **Killing the plugin doesn't end the session in SSM.** It stays listed as "Active". `root_wrap()` reads the session ID from the plugin's output and calls `aws ssm terminate-session`, and the e2e tests check that no sessions stay open.
- **Run Command stores the command and its output for 30 days** and writes the script to the node's disk. So `vault-ops.sh` uses it only for commands without secrets, and sessions for anything that involves a token or might print secret data.

## Terraform and the AWS provider

- **`user_data_replace_on_change` isn't reliable with `user_data_base64`.** When the user data depends on a value that's unknown at plan time (a new volume's ID, for example), the provider plans an in-place update, then fails during apply with "Provider produced inconsistent final plan". The instance in [modules/vault-node/main.tf](modules/vault-node/main.tf) uses `replace_triggered_by` on a `terraform_data` holding a hash of the user data instead.
- **A failed `precondition` or `check` prints the value of every expression in its condition.** Referencing a large value directly dumps it into the error. The user data size check compares a separate local that holds only the length.
- **`terraform workspace new` also selects the new workspace** for that directory, so afterwards plain `terraform` commands there quietly use it. [tests/e2e.sh](tests/e2e.sh) selects the previous workspace again.
- **With no state at all, `terraform output -raw <name>` succeeds and prints nothing.** Check for an empty value, not just the exit code (the pre-flight checks in `vault-ops.sh`).

## EC2 and Amazon Linux

- **The 16 KB user data limit counts the bytes EC2 stores,** that is, gzipped data after base64 decoding. cloud-init unpacks gzip on the node, so gzipping is what makes room. Terraform can't measure the gzipped bytes directly (`base64decode` needs UTF-8), but 16384 bytes are exactly 21848 base64 characters.
- **AWS deprecates Amazon Linux 2023 AMIs about 90 days after release,** and the `aws_ami` data source skips deprecated images by default, so a pinned AMI name makes every plan fail from then on. Deprecated AMIs still launch: the repo sets `include_deprecated = true` and warns with a `check` block.
- **Amazon Linux 2023 pins `dnf` to the release the AMI was built from,** so `dnf upgrade` on a running node gets few updates. Patching means moving to a newer AMI, which fits replacing nodes rather than patching them.
- **`list-objects-v2 --query KeyCount` prints `None`, not `0`, for an empty result** (the CLI paginates). Compare the listed key instead.

## Vault and its packages

- **Not every Vault release is in HashiCorp's Amazon Linux RPM repo** (2.1.0 isn't, for example). Check with `dnf --showduplicates list vault` before pinning a version.
- **A Raft snapshot restore needs an initialised Vault and a token.** An empty node initialises a throwaway Vault first, restores over it, and never stores the throwaway output. With the same KMS key, the restored Vault unseals itself and has its original root token and recovery keys back.
- **An auth method's configuration lives in Vault's data.** The `raft-snapshot` role bound to the node's IAM role survives node replacement and restores, which is why the role has a fixed name: a new name would break the binding.
- **The Vault RPM's `vault.service` reads `/etc/vault.d/vault.env`,** and the `awskms` seal takes its key and region from `VAULT_AWSKMS_SEAL_KEY_ID` and `AWS_REGION`. So the Vault config file needs no deployment-specific values.

## systemd

- **`Requires=` starts the required unit.** A snapshot service with `Requires=vault.service` would start a Vault that was stopped on purpose. `Requisite=` only runs when Vault is already active.
- **A unit that is stopped at shutdown can run a last job.** `vault-snapshot-on-stop.service` is ordered after `vault.service` and the network, so it stops before them and its `ExecStop` takes a final snapshot. Terraform stops the old instance before detaching the volume, so every replacement leaves a fresh snapshot behind.
