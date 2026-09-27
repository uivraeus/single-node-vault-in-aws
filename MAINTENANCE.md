# Maintaining the Vault node with "just Terraform"

How the demo handles Vault upgrades, OS upgrades, resizing, moving between availability zones, and recovery, all without configuration management on the node.

The idea: **never upgrade the node in place; replace it**. That's only safe if everything worth keeping lives outside the instance:

| State | Lives in | Module | Survives node replacement |
|---|---|---|---|
| Raft data | EBS volume, mounted at `/opt/vault/data` | `vault-data` | Yes (same AZ) |
| Raft snapshots | Versioned S3 bucket, one key `raft/latest.snap` | `vault-data` | Yes (any AZ) |
| Unseal key | KMS | `vault-data` | Yes. **Without it, data and snapshots are unreadable.** |
| Root token + recovery keys | Secrets Manager / Parameter Store | root `secret.tf` | Yes |
| Node config | `user_data`: cloud-config with the files in `modules/vault-node/node-files/` plus generated settings | `vault-node` | Recreated on every new node |

Any change to `user_data` (Vault version, a file in `node-files/`, snapshot settings) replaces the instance: Terraform plans that itself (`replace_triggered_by`), also when a new value is only known during apply, such as a new volume's ID. Terraform stops the old instance before detaching the volume, so Vault shuts down cleanly and takes a snapshot on the way out.

All commands below run from a Terraform root (`secrets-manager/` or `parameter-store/`); use `-C <dir>` to run from elsewhere.

`vault-ops.sh` runs Vault commands with the node's own `vault` CLI, so its version always matches the server, even halfway through an upgrade or a restore. It reads the root token with your AWS credentials, uses it locally (through a throwaway port forward) to mint a short-lived child token, and sends the node only a response-wrapped copy of that: single use, valid for 60 seconds. The root token never leaves your machine, and the command and its output travel over an SSM session, so nothing is kept in Run Command history.

## Everyday changes

| Change | How | What happens |
|---|---|---|
| Vault upgrade | `vault_version` | New node, same data volume. Vault migrates the data on start. |
| OS upgrade | `ami_name` | New node, same data volume. |
| Resize, same architecture | `instance_type` | In place: stop, change type, start. |
| Resize to another architecture | `instance_type` + `ami_name` (the `-arm64`/`-x86_64` image) | New node, same data volume. Raft data works on both arm64 and x86_64. |
| Move to another AZ | `subnet_id` | New volume (empty), new node, **restored from the latest snapshot**. The old volume is deleted. |
| Rebuild the node | `-replace=module.node.aws_instance.vault` | New node, same data volume. |

Put the new values in `variables.tf` defaults or a `.tfvars` file, not only in `-var`: a later plain `terraform apply` would otherwise go back to the old values. For `vault_version`, going back would be a downgrade, which Vault doesn't support.

Use the wrapper rather than plain `terraform apply`:

```bash
../scripts/vault-ops.sh apply                          # after editing the defaults
../scripts/vault-ops.sh apply -var vault_version=2.1.1 # or ad hoc (see above)
```

It takes a snapshot first and **refuses to apply if that fails**. Without it you'd find out the shutdown snapshot failed when you needed it. After the apply it waits until the (possibly new) node has finished its bootstrap and Vault is unsealed, then prints its status, including whether the new node already uploaded a snapshot. If the bootstrap failed (a refused init, a failed restore), it stops right away and shows the end of the bootstrap log instead of waiting for a timeout.

**Rolling back an upgrade:** Vault can't downgrade its data. Set the old `vault_version` again, apply, then `restore` the `pre-apply` snapshot that the wrapper took (see below).

**Security updates between AMI bumps:** AL2023 locks `dnf` to the release the AMI was built from, so `dnf upgrade` on the node gets few updates. Bump `ami_name` regularly instead (AWS publishes new AMIs roughly weekly). AWS deprecates each AL2023 AMI about 90 days after release: from then on every `plan` shows a warning (`check "ami_not_deprecated"`), but nothing fails, because deprecated AMIs can still be launched. Only images owned by Amazon are accepted. List the latest releases with:

```bash
aws ec2 describe-images --owners amazon --filters 'Name=name,Values=al2023-ami-2023.*-kernel-6.12-arm64' \
  --query 'reverse(sort_by(Images,&CreationDate))[:5].Name' --output text
```

## Snapshots

The node uploads Raft snapshots to `s3://<snapshot_bucket>/raft/latest.snap`. Each upload is a new version of that key, and noncurrent versions expire after `snapshot_retention_days` (default 30). The current version never expires, so you always keep at least one snapshot.

| Taken | Reason (S3 metadata) |
|---|---|
| Every hour (`snapshot_schedule`, a systemd `OnCalendar` value) | `scheduled` |
| When the node shuts down cleanly (stop, resize, Terraform replacement) | `shutdown` |
| When the node finishes bootstrapping | `bootstrap` |
| Before `vault-ops.sh apply` / `restore` | `pre-apply` / `pre-restore` |
| `vault-ops.sh snapshot [reason]` | `manual` or your reason |

```bash
../scripts/vault-ops.sh snapshot
../scripts/vault-ops.sh snapshots 5
# VERSION_ID                         LAST_MODIFIED                  BYTES  METADATA
# Qkmk69jorWEVmIqpTirgqWrXr8oNgSSC   2026-09-26T08:24:43+00:00      26601  {"reason":"shutdown",...}
```

How the node authenticates: at first init the bootstrap uses the new root token once to enable Vault's AWS auth method (`vault-configure-snapshots.sh`). It creates a role `raft-snapshot`, bound to the node's IAM role ARN, whose only policy is `read` on `sys/storage/raft/snapshot`. That configuration is part of Vault's data, so it carries over to replacement nodes and through restores. If it's ever broken or missing, `vault-ops.sh configure-snapshots` sets it up again. No token is stored on the node, and the node's IAM role can write and read `raft/latest.snap` but can't delete versions. The IAM role has a fixed name (`<name>-vault-node`), so a recreated role still matches the binding.

Vault Enterprise has built-in automated snapshots; this systemd timer is the Community Edition equivalent.

## Recovery

### What a new node does at first boot

0. Enable the snapshot timer and the shutdown snapshot, before anything else: then no later failure can skip it, and a manual re-run of the bootstrap still leaves a node that takes snapshots. An early snapshot attempt is harmless, because the login only works once Vault holds real data (the `raft-snapshot` auth role lives there), so an empty or throwaway Vault is never uploaded.
1. Wait for the data volume. If it has a file system, reuse it; if it's blank, format it.
2. Vault already initialised (the data volume came from a previous node)? Done.
3. Otherwise, if S3 has a snapshot, initialise a **throwaway** Vault and restore the snapshot over it. The restore brings back the original root token and recovery keys, and the same KMS key unseals it. The throwaway root token and recovery key are discarded and never stored.
4. No snapshot, but the store already holds init output? **Refuse** (see below).
5. Otherwise, initialise, store the init output, and set up snapshot auth. If the init output can't be stored, the new (empty) Vault is discarded rather than the output kept anywhere else; re-run the bootstrap after fixing the cause.
6. Mark the bootstrap as done. `vault-ops.sh wait-ready` waits for this marker, so a node that refused or failed never counts as ready (and `wait-ready` says so right away), while one repaired by hand does.

The node checks step 4 with metadata only (`secretsmanager:DescribeSecret` / `ssm:DescribeParameters`); it still can't read the value.

### Roll back Vault's data

Roll back to an older snapshot, for example after a bad change or a failed upgrade:

```bash
../scripts/vault-ops.sh snapshots 10
../scripts/vault-ops.sh restore <version-id>
```

`restore` first saves the current state as a `pre-restore` snapshot, then makes the chosen version the latest one (`promote`), and restores that on the node with a short-lived root token; the node's own role can't restore. To undo the restore, restore the `pre-restore` version. Afterwards the root token and recovery keys are the ones that were valid when the snapshot was taken. If you rotated the root token since then, the stored init output no longer matches.

### A new node can't restore the latest snapshot

The bootstrap stops Vault (so nothing mistakes the empty throwaway Vault for the real one) and logs:

```
ERROR: restore failed; Vault stopped. To retry on this node:
  sudo sh -c 'rm -rf /opt/vault/data/* && systemctl start vault && /usr/local/bin/vault-bootstrap.sh'
```

Make a good version the latest, then run that retry command (through `vault-ops.sh run` or a shell):

```bash
../scripts/vault-ops.sh promote <good-version-id>
../scripts/vault-ops.sh run "sh -c 'rm -rf /opt/vault/data/* && systemctl start vault && /usr/local/bin/vault-bootstrap.sh'"
../scripts/vault-ops.sh wait-ready
```

### "Refusing to initialise a new, empty Vault"

The node has an empty data volume, no snapshot exists, and a previous node already stored init output. Initialising would overwrite that root token and those recovery keys with ones for an empty Vault. That matters if the old data can still be recovered some other way, because the stored output is what gives you administrative access to it. Likely causes:

- **Snapshots were silently failing, and the data volume was then lost or replaced** (for example by an AZ move). `vault-ops.sh status` shows the age of the latest snapshot and whether this node took it; `vault-ops.sh configure-snapshots` repairs broken snapshot auth.
- **The secret outlived the snapshot bucket:** Secrets Manager's `restore-secret` after a `terraform destroy`, or a data layer recreated separately from the secret.
- **The snapshots were deleted by hand.**

Either get data back (a volume, or a snapshot version you then `promote`) and re-run the bootstrap, or start from scratch on purpose:

```bash
../scripts/vault-ops.sh run 'touch /etc/vault.d/allow-new-vault && /usr/local/bin/vault-bootstrap.sh'
```

The override is removed after use. The previous init output stays in the store's version history (see [SNIPPETS.md §5](SNIPPETS.md#5-history-and-undo)), but how long differs: Parameter Store keeps the last 100 versions, while Secrets Manager only labels the single previous value `AWSPREVIOUS`, so after one more write the original becomes unlabeled and can be cleaned up.

### Other helpers

```bash
../scripts/vault-ops.sh status                    # instance, Vault, mount, bootstrap, snapshot timer, age of latest snapshot
../scripts/vault-ops.sh configure-snapshots       # (re)create the Vault auth the node uses for snapshots
../scripts/vault-ops.sh logs [-f]                 # the bootstrap log (-f: follow)
../scripts/vault-ops.sh shell                     # interactive shell on the node
../scripts/vault-ops.sh port-forward [port]       # Vault on localhost for your own tools
../scripts/vault-ops.sh run 'journalctl -u vault-snapshot --since today --no-pager'
../scripts/vault-ops.sh vault kv get kv/foo       # the node's vault CLI as root (short-lived token)
```

## Testing

`tests/e2e.sh` exercises all of the above against real AWS resources: upgrades, resizing, an AZ move, rollbacks, a corrupt snapshot, the refusal guard and a failing store write. It runs in a separate Terraform workspace, so it never touches your lab deployment. Noteworthy results are recorded in [tests/LOG.md](tests/LOG.md); what surprised us while building and testing it is in [LESSONS.md](LESSONS.md).

## What "just Terraform" doesn't cover

- **Ordered steps with checks.** Terraform can't run "snapshot, change, verify, roll back if broken". `vault-ops.sh apply` covers the first and third steps; rolling back is a human decision. An SSM Automation document (defined in Terraform, started separately) is the AWS-native alternative.
- **Moving AZ deletes the old volume** before anyone checks the restore on the new one. The `pre-apply` and `shutdown` snapshots are the safety net. With `prevent_destroy` on the volume (see below), the plan fails instead and you move deliberately.
- **Nothing alerts when snapshots stop.** `vault-ops.sh status` warns when the latest snapshot is older than two hours, but only when someone looks. For an alert, have the snapshot script publish a CloudWatch metric and add an alarm that fires on missing data (`treat_missing_data = "breaching"`).
- **Clusters with several nodes.** Rolling upgrades (standbys first, leader last, waiting for Raft health between nodes) are orchestration. An auto scaling group's instance refresh gets part of the way.
- **Vault's own configuration** (auth methods, policies, mounts) belongs in a separate root using the Vault provider, which needs a token and writes some secrets into state.

## Production notes

- Put `vault-data` in **its own Terraform root/state**, with `prevent_destroy` on the key, volume and bucket, and no `force_destroy`, so no `terraform destroy` of the node can reach them. The demo keeps both modules in one root for easy teardown.
- Snapshots are only as durable as the KMS key: use a long deletion window, and for regional disaster recovery a multi-Region key plus cross-Region replication of the bucket. Consider S3 Object Lock for snapshots.
- For self-healing, run an auto scaling group of one instead of `aws_instance`. The instance then attaches its own volume (needs `ec2:AttachVolume`), or restores from S3 if it lands in another AZ. The bootstrap already handles that case.
- Bake Vault into an AMI (Packer) to avoid depending on the HashiCorp RPM repo at boot. The files in `node-files/` are exactly what the image build would copy in. (User data is gzipped: EC2's 16 KB limit counts the gzipped bytes, about 5 KB now. A precondition on the instance stops a plan that would exceed it.)
- With TLS, use a stable DNS name for `api_addr`/`cluster_addr` and keep `node_id` fixed. The node identity is part of the Raft data and must not depend on the instance's IP.
