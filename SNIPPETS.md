# Vault init secrets: commands and snippets

Commands for writing, reading, rotating and cleaning up the Vault init output (root token + recovery keys) in **Secrets Manager** (SM) or **SSM Parameter Store** (PS). Names match the Terraform defaults (`name = "vault-demo"`):

| | Secrets Manager | Parameter Store |
|---|---|---|
| Name | `vault/vault-demo/init` | `/vault/vault-demo/init` |
| Written by | Vault node (`PutSecretValue` only) | Vault node (`PutParameter` only) |
| Read by | Humans with their own AWS credentials | Humans with their own AWS credentials |

The init JSON looks like this:

```json
{
  "unseal_keys_b64": [], "unseal_keys_hex": [], "unseal_shares": 1, "unseal_threshold": 1,
  "recovery_keys_b64": ["...", "...", "..."], "recovery_keys_hex": ["...", "...", "..."],
  "recovery_keys_shares": 3, "recovery_keys_threshold": 2,
  "root_token": "hvs.XXXXXXXX"
}
```

Set these once per shell to shorten the commands below:

```bash
export AWS_REGION=eu-north-1
SM_ID=vault/vault-demo/init
PS_NAME=/vault/vault-demo/init
INSTANCE_ID=$(terraform -chdir=secrets-manager output -raw instance_id)   # or parameter-store
```

---

## 1. Reaching Vault

The listener binds to `127.0.0.1` only, so all access goes through SSM. `scripts/vault-ops.sh` wraps the common cases (run from a Terraform root):

```bash
../scripts/vault-ops.sh shell            # shell on the node (as ssm-user; the instance role can't read the secret)
../scripts/vault-ops.sh port-forward     # Vault on localhost:8200 until Ctrl-C, for your own vault CLI or tools
../scripts/vault-ops.sh logs -f          # follow the bootstrap log
../scripts/vault-ops.sh vault status     # the node's vault CLI as root, no local CLI or port forward needed
```

The raw commands behind the first two:

```bash
aws ssm start-session --target "$INSTANCE_ID"
aws ssm start-session --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters portNumber=8200,localPortNumber=8200
export VAULT_ADDR=http://127.0.0.1:8200
```

The rest of this file uses your own `vault` CLI through that port forward.

---

## 2. Writing the init output (on the node)

This is what `modules/vault-node/node-files/vault-bootstrap.sh` does. The core idea: pipe the init output straight into the store. It only ever lives in memory.

```bash
INIT=$(vault operator init -format=json -recovery-shares=3 -recovery-threshold=2)

# Secrets Manager
aws secretsmanager put-secret-value --secret-id "$SM_ID" \
  --secret-string file:///dev/stdin <<<"$INIT"

# Parameter Store
aws ssm put-parameter --name "$PS_NAME" --type SecureString --overwrite \
  --value file:///dev/stdin <<<"$INIT"
```

The bootstrap script also:
- leaves an initialised Vault alone (safe to re-run: `sudo /usr/local/bin/vault-bootstrap.sh`), restores the latest snapshot onto an empty data volume instead of initialising, and refuses to initialise over init output an earlier node already stored (see [MAINTENANCE.md](MAINTENANCE.md#recovery)),
- retries the write (IAM changes can take a moment to reach a new node),
- if storing keeps failing, **discards** the new Vault (stops it, wipes `/opt/vault/data`) instead of keeping the init output anywhere else. Nothing is lost: it was a brand-new, empty Vault. Fix the cause (usually the node's permission to write the store), then initialise again:

```bash
../scripts/vault-ops.sh run 'systemctl start vault && /usr/local/bin/vault-bootstrap.sh'
../scripts/vault-ops.sh wait-ready
```

---

## 3. Reading

```bash
# Whole init JSON
aws secretsmanager get-secret-value --secret-id "$SM_ID" --query SecretString --output text | jq .
aws ssm get-parameter --name "$PS_NAME" --with-decryption --query Parameter.Value --output text | jq .

# Just the root token
aws secretsmanager get-secret-value --secret-id "$SM_ID" --query SecretString --output text | jq -r .root_token
aws ssm get-parameter --name "$PS_NAME" --with-decryption --query Parameter.Value --output text | jq -r .root_token

# Just the recovery keys
... | jq -r '.recovery_keys_b64[]'
```

### `vault-login`: a shell helper for everyone on the team

Put it in `~/.bashrc` / `~/.zshrc`. Run it with the port forward active.

```bash
# usage: vault-login [name] [sm|ps]
vault-login() {
  local name=${1:-vault-demo} store=${2:-sm} init
  case $store in
    sm) init=$(aws secretsmanager get-secret-value --secret-id "vault/$name/init" \
                 --query SecretString --output text) ;;
    ps) init=$(aws ssm get-parameter --name "/vault/$name/init" --with-decryption \
                 --query Parameter.Value --output text) ;;
    *)  echo "store must be sm or ps" >&2; return 1 ;;
  esac || return 1
  VAULT_TOKEN=$(jq -r .root_token <<<"$init") || return 1
  export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN
  vault token lookup -format=json | jq '.data | {display_name, policies}'
}
```

For Terraform against Vault itself ([vault-config/](vault-config/)), use `scripts/vault-ops.sh tf` instead: it opens the port forward, and after the first apply Terraform logs in with your AWS credentials, not the root token (see the [README](README.md#configuring-vault-with-terraform)). Never read the root token with a Terraform `data` source; that writes it into state.

---

## 4. Rotating the root token (for example when someone leaves)

Uses the stored recovery keys to run `generate-root`, stores the new token, and only then revokes the old one. Run it with the port forward active.

Since **Vault 2.0**, `sys/generate-root` needs a valid Vault token **in addition to** the key shares (it was unauthenticated before). The script authenticates with the current root token. If that token is lost or broken, see [4b](#4b-lost-root-token-generate-root-without-a-token).

```bash
#!/usr/bin/env bash
# rotate-root.sh [sm|ps] [name]
set -euo pipefail
STORE=${1:-sm}; NAME=${2:-vault-demo}
export VAULT_ADDR=${VAULT_ADDR:-http://127.0.0.1:8200}

read_init() {
  case $STORE in
    sm) aws secretsmanager get-secret-value --secret-id "vault/$NAME/init" --query SecretString --output text ;;
    ps) aws ssm get-parameter --name "/vault/$NAME/init" --with-decryption --query Parameter.Value --output text ;;
  esac
}
write_init() {   # JSON on stdin
  case $STORE in
    sm) aws secretsmanager put-secret-value --secret-id "vault/$NAME/init" --secret-string file:///dev/stdin >/dev/null ;;
    ps) aws ssm put-parameter --name "/vault/$NAME/init" --type SecureString --overwrite --value file:///dev/stdin >/dev/null ;;
  esac
}

INIT=$(read_init)
OLD_TOKEN=$(jq -r .root_token <<<"$INIT")
THRESHOLD=$(jq -r .recovery_keys_threshold <<<"$INIT")

# Vault 2.x: generate-root needs a token too. If the stored one is dead, fall back
# to unauthenticated access, which must be enabled on the node first (see 4b).
export VAULT_TOKEN=$OLD_TOKEN
if vault token lookup >/dev/null 2>&1; then
  OLD_VALID=true
else
  echo "Stored root token is invalid; relying on enable_unauthenticated_access (see 4b)." >&2
  OLD_VALID=false
  unset VAULT_TOKEN
fi

vault operator generate-root -cancel >/dev/null          # clear any stale attempt
ATTEMPT=$(vault operator generate-root -init -format=json)
NONCE=$(jq -r .nonce <<<"$ATTEMPT")
OTP=$(jq -r .otp <<<"$ATTEMPT")

# Recovery keys are passed as arguments: visible in the local process list for a moment.
for KEY in $(jq -r ".recovery_keys_b64[:$THRESHOLD][]" <<<"$INIT"); do
  RESULT=$(vault operator generate-root -format=json -nonce="$NONCE" "$KEY")
done
NEW_TOKEN=$(vault operator generate-root -decode="$(jq -r .encoded_token <<<"$RESULT")" -otp="$OTP")

# Store first, then revoke, so there is always a working root token on record.
jq --arg t "$NEW_TOKEN" '.root_token = $t' <<<"$INIT" | write_init
if $OLD_VALID; then VAULT_TOKEN=$NEW_TOKEN vault token revoke "$OLD_TOKEN"; fi
echo "Root token rotated and stored."
```

### 4b. Lost root token: generate-root without a token

If the stored token no longer works, you can't authenticate to `generate-root`. Temporarily allow unauthenticated access on the node (in an SSM shell), run `rotate-root.sh` as usual (it notices the dead token), then turn it off again:

```bash
# on the node: add the top-level setting and reload (SIGHUP, no restart needed)
echo 'enable_unauthenticated_access = ["generate-root"]' | sudo tee -a /etc/vault.d/vault.hcl
sudo systemctl reload vault

# on your machine (port forward active):  ./rotate-root.sh sm   # or ps

# afterwards: remove it again and reload
sudo sed -i '/^enable_unauthenticated_access/d' /etc/vault.d/vault.hcl
sudo systemctl reload vault
```

---

## 5. History and undo

Both stores keep earlier values, which helps if something overwrites the secret. A node with an empty data volume restores from the latest snapshot instead of initialising, and refuses to initialise over existing init output when there is no snapshot (see [MAINTENANCE.md](MAINTENANCE.md#recovery)), so this should only happen on purpose.

```bash
# Secrets Manager: versions are labelled AWSCURRENT / AWSPREVIOUS
aws secretsmanager list-secret-version-ids --secret-id "$SM_ID"
aws secretsmanager get-secret-value --secret-id "$SM_ID" --version-stage AWSPREVIOUS \
  --query SecretString --output text | jq .

# Parameter Store: numbered versions (the last 100 are kept)
aws ssm get-parameter-history --name "$PS_NAME" --with-decryption \
  --query 'Parameters[].{v:Version,modified:LastModifiedDate,by:LastModifiedUser}' --output table
aws ssm get-parameter --name "$PS_NAME:2" --with-decryption --query Parameter.Value --output text | jq .
```

---

## 6. Who read it? (CloudTrail)

Reads are management events, so they're logged by default and kept for 90 days in the event history.

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=GetSecretValue \
  --query 'Events[].{time:EventTime,user:Username,res:Resources[0].ResourceName}' --output table

aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=GetParameter \
  --query 'Events[].{time:EventTime,user:Username,res:Resources[0].ResourceName}' --output table
```

---

## 7. Check that Terraform state doesn't hold the secret

Run this after the node has bootstrapped **and** after a later `terraform plan` (the refresh is when a provider would read the value back).

```bash
terraform -chdir=secrets-manager state pull | grep -c 'hvs\.'     # expect 0
terraform -chdir=parameter-store state pull | grep -c 'hvs\.'     # expect 0

# Parameter Store: value should be empty/null with the write-only attribute
terraform -chdir=parameter-store state pull \
  | jq '.resources[] | select(.type=="aws_ssm_parameter") | .instances[].attributes | {value, has_value_wo}'
```

---

## 8. Teardown and leftovers

```bash
terraform -chdir=secrets-manager destroy
terraform -chdir=parameter-store destroy
```

| Resource | After `terraform destroy` |
|---|---|
| PS parameter | Deleted immediately. No undo. |
| SM secret, `recovery_window_in_days = 0` | Deleted immediately. |
| SM secret, window 7–30 | Scheduled for deletion; the name stays reserved, so re-applying with the same `name` fails until the window ends (or you restore / force-delete). |
| KMS unseal key | Scheduled for deletion (7 days in this demo). Any Vault data or snapshot is unrecoverable once it's gone. |
| EBS data volume | Deleted immediately. |
| S3 snapshot bucket | Deleted with all snapshot versions (`force_destroy` in this demo). |

```bash
# Secrets Manager: find, restore or force-delete pending secrets
aws secretsmanager list-secrets --include-planned-deletion \
  --filters Key=name,Values=vault/ --query 'SecretList[].{name:Name,deleted:DeletedDate}'
aws secretsmanager restore-secret --secret-id "$SM_ID"
aws secretsmanager delete-secret --secret-id "$SM_ID" --force-delete-without-recovery

# KMS: undo a scheduled key deletion (key goes back to Disabled, so enable it again)
KEY_ID=$(terraform -chdir=secrets-manager output -raw kms_unseal_key_arn)   # before destroy
aws kms cancel-key-deletion --key-id "$KEY_ID"
aws kms enable-key --key-id "$KEY_ID"

# Anything left behind with the demo's tags? (The tagging API lists deleted resources
# for a while; check suspicious ones with the service's own describe call.)
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=vault-demo \
  --query 'ResourceTagMappingList[].ResourceARN'
```

The e2e tests (`tests/e2e.sh`) use the Terraform workspace `e2e` and names starting with `vault-e2e-`, and destroy their resources at the end. If a run was killed hard:

```bash
TF_WORKSPACE=e2e TF_VAR_name=vault-e2e-sm terraform -chdir=secrets-manager destroy   # or -ps / parameter-store
```
