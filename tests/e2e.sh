#!/usr/bin/env bash
# End-to-end tests against real AWS resources, using the real Terraform roots.
#
# usage: tests/e2e.sh [--store sm|ps] [--keep] [smoke | full | <scenario>...]
#
#   --store sm|ps   secrets-manager (default) or parameter-store root
#   --keep          don't destroy the test deployment at the end (debugging)
#   smoke           ~10 min: deploy, canary, snapshot, replace node, rollback, snapshot auth repair
#   full            ~25 min (sm) / ~10 min (ps): everything that applies to the store
#   <scenario>...   run just these, in order (the first one should be a deploy)
#
# Isolation: a separate Terraform workspace (e2e) in the root, and resource names
# starting with vault-e2e-, so a lab deployment in the default workspace is never
# touched. Everything is destroyed on exit, also on failure or Ctrl-C.
#
# Prints PASS/FAIL per check; the full output goes to tests/.runs/<timestamp>.log.
# At the end it prints a Markdown summary for tests/LOG.md.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
STORE=sm KEEP=false
while [ $# -gt 0 ]; do
  case $1 in
    --store) STORE=$2; shift 2 ;;
    --keep)  KEEP=true; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) break ;;
  esac
done
case $STORE in
  sm) TF_ROOT=$REPO/secrets-manager ;;
  ps) TF_ROOT=$REPO/parameter-store ;;
  *)  echo "--store must be sm or ps" >&2; exit 1 ;;
esac

SMOKE="deploy canary snapshot replace_node rollback snapshot_auth_repair"
FULL_SM="deploy_old canary snapshot upgrade resize_in_place arch_switch az_move rollback snapshot_auth_repair requisite corrupt_snapshot refusal store_failure"
FULL_PS="deploy canary replace_node snapshot_auth_repair refusal store_failure"
case ${1:-smoke} in
  smoke) SCENARIOS=$SMOKE; TIER=smoke ;;
  full)  if [ "$STORE" = sm ]; then SCENARIOS=$FULL_SM; else SCENARIOS=$FULL_PS; fi; TIER=full ;;
  *)     SCENARIOS="$*"; TIER=custom ;;
esac

# --- Isolation -----------------------------------------------------------------------
export TF_WORKSPACE=e2e TF_VAR_name=vault-e2e-$STORE TF_IN_AUTOMATION=1
case $TF_VAR_name in vault-e2e-*) ;; *) echo "refusing: name must start with vault-e2e-" >&2; exit 1 ;; esac
# TF_WORKSPACE must name an existing workspace, so create it without that set.
# `workspace new` also selects it for the directory: put the previous one back, or
# plain terraform commands in the root would silently use the e2e state afterwards.
(
  unset TF_WORKSPACE
  previous=$(terraform -chdir="$TF_ROOT" workspace show)
  terraform -chdir="$TF_ROOT" workspace new e2e >/dev/null 2>&1 || true
  terraform -chdir="$TF_ROOT" workspace select "$previous" >/dev/null
)
terraform -chdir="$TF_ROOT" init -input=false >/dev/null

# Versions for the upgrade scenario: start one release behind the defaults.
OLD_VAULT=2.0.4   # must exist in the HashiCorp RPM repo (not every release does, e.g. 2.1.0)
OLD_AMI=al2023-ami-2023.9.20251020.0-kernel-6.1-arm64
DEFAULT_AMI=$(terraform -chdir="$TF_ROOT" console <<<'var.ami_name' | tr -d '"')   # console prints it quoted

mkdir -p "$REPO/tests/.runs"
LOG=$REPO/tests/.runs/$(date -u +%Y%m%dT%H%M%SZ)-$STORE-$TIER.log
CANARY="e2e-$(date +%s)"
TMP=$(mktemp -d)
RESULTS=()
START=$SECONDS

ops() { "$REPO/scripts/vault-ops.sh" -C "$TF_ROOT" "$@"; }
say() { echo "$*" | tee -a "$LOG"; }

# check <description> <command...>: run quietly (output to the log), report ok/FAIL.
check() {
  local desc=$1; shift
  echo "--- check: $desc" >>"$LOG"
  if "$@" >>"$LOG" 2>&1; then say "    ok    $desc"; else say "    FAIL  $desc"; return 1; fi
}
# expect <description> <expected> <command...>: like check, comparing the output.
expect() {
  local desc=$1 want=$2 got; shift 2
  echo "--- expect: $desc (want: $want)" >>"$LOG"
  got=$("$@" 2>>"$LOG" | tail -1) || true
  echo "got: $got" >>"$LOG"
  if [ "$got" = "$want" ]; then say "    ok    $desc"; else say "    FAIL  $desc (want '$want', got '$got')"; return 1; fi
}
quiet() { "$@" >>"$LOG" 2>&1; }

bootstrap_log_has() { ops run "grep -q '$1' /var/log/vault-bootstrap.log"; }
canary_is() { expect "canary reads '$1'" "$1" ops vault kv get -field=value kv/canary; }
node_field() {   # instance type, arch or AMI release, from `status`
  ops status | awk -v f="$1" '/^instance:/ { if (f == "type") print $2; if (f == "arch") print $3; if (f == "release") print $4 }'
}
node_vault_version() { ops status | awk '/^Vault v/ { print $2 }'; }   # e.g. v2.1.1
# The "reason" metadata of the newest snapshot (second line of `snapshots`, after the header)
latest_reason() { ops snapshots 1 | awk 'NR == 2' | sed -E 's/.*"reason":"([^"]*)".*/\1/'; }
latest_version() { ops snapshots 1 | awk 'NR == 2 { print $1 }'; }
# Wait until cloud-init on the node is done or failed (the bootstrap log tells which).
# (cloud-init status exits non-zero on error, so don't rely on run's exit code)
wait_cloud_init() {
  local out
  for _ in $(seq 90); do
    out=$(ops run 'cloud-init status' 2>/dev/null || true)
    grep -qE 'status: (done|error)' <<<"$out" && return 0
    sleep 10
  done
  return 1
}
shutdown_snapshot_from() { ops snapshots 5 | grep "$1" | grep -q '"reason":"shutdown"'; }
# SSM sessions to this node still listed as active. vault-ops.sh must end every
# session it opens (killing the plugin alone leaves them "Active"). SSM can take a
# few seconds to update, so wait a little for zero.
no_active_sessions() {
  local instance n
  instance=$(terraform -chdir="$TF_ROOT" output -raw instance_id)
  for _ in $(seq 10); do
    n=$(aws ssm describe-sessions --state Active --filters "key=Target,value=$instance" --query 'length(Sessions)')
    [ "$n" = 0 ] && return 0
    sleep 3
  done
  echo "still active: $n"
  return 1
}
# Nothing that looks like init output anywhere the bootstrap could have put it
no_init_output_on_disk() {
  ops run '! test -e /root/vault-init.json && ! grep -rqs recovery_keys /root /tmp /var/tmp /var/log /etc/vault-node /etc/vault.d'
}
# Expands on the node, not here.
# shellcheck disable=SC2016
vault_discarded() { ops run '! systemctl is-active -q vault && [ -z "$(ls -A /opt/vault/data)" ]'; }
init_with_broken_store_fails() {
  ! ops run 'touch /etc/vault.d/allow-new-vault && /usr/local/bin/vault-bootstrap.sh'
}
snapshot_fails() { ! ops snapshot e2e-should-fail; }
# The node can't become ready without a human: wait-ready must say so right away,
# not after its timeout.
wait_ready_fails_fast() { local t0=$SECONDS; ! ops wait-ready 600 && [ $((SECONDS - t0)) -lt 120 ]; }
snapshot_service_refuses() { ! ops run 'systemctl start vault-snapshot.service'; }
vault_state() { ops run 'systemctl is-active vault || true'; }
# Plain terraform apply for scenarios that break the node on purpose: vault-ops.sh
# apply would refuse (no pre-apply snapshot possible) or wait for a node that won't be ready.
tf_apply() { quiet terraform -chdir="$TF_ROOT" apply -auto-approve -input=false "$@"; }
other_az_subnet() {
  local current
  current=$(aws ec2 describe-instances --instance-ids "$(terraform -chdir="$TF_ROOT" output -raw instance_id)" \
    --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)
  aws ec2 describe-subnets --filters Name=default-for-az,Values=true \
    --query "Subnets[?AvailabilityZone!='$current'] | [0].SubnetId" --output text
}
# Make the node stop taking snapshots (for scenarios that need "no good snapshot").
disable_node_snapshots() { quiet ops run 'chmod -x /usr/local/bin/vault-snapshot.sh'; }

# --- Scenarios -----------------------------------------------------------------------
# Each runs on the deployment the previous one left behind.

sc_deploy() {
  quiet terraform -chdir="$TF_ROOT" apply -auto-approve -input=false
  check "node ready" ops wait-ready
  check "fresh init path taken" bootstrap_log_has 'Vault state: empty$'
  expect "bootstrap snapshot uploaded" bootstrap latest_reason
}

sc_deploy_old() {
  export TF_VAR_vault_version=$OLD_VAULT TF_VAR_ami_name=$OLD_AMI
  sc_deploy
  expect "old Vault version" "v$OLD_VAULT" node_vault_version
}

sc_canary() {
  quiet ops vault secrets enable -path=kv kv-v2
  quiet ops vault kv put kv/canary value="$CANARY"
  canary_is "$CANARY"
  check "no SSM sessions left open" no_active_sessions
}

sc_snapshot() {
  check "manual snapshot" ops snapshot e2e
  expect "latest snapshot is ours" e2e latest_reason
}

sc_replace_node() {
  local before
  before=$(terraform -chdir="$TF_ROOT" output -raw instance_id)
  quiet ops apply -auto-approve -input=false -replace=module.node.aws_instance.vault
  check "new instance" test "$(terraform -chdir="$TF_ROOT" output -raw instance_id)" != "$before"
  check "existing data kept" bootstrap_log_has 'Vault state: initialised'
  check "shutdown snapshot from the old node" shutdown_snapshot_from "$before"
  canary_is "$CANARY"
}

sc_upgrade() {
  unset TF_VAR_vault_version TF_VAR_ami_name   # back to the defaults
  quiet ops apply -auto-approve -input=false
  check "existing data kept" bootstrap_log_has 'Vault state: initialised'
  expect "Vault upgraded" "v$(terraform -chdir="$TF_ROOT" console <<<'var.vault_version' | tr -d '"')" node_vault_version
  check "OS upgraded" test "$(node_field release)" != "2023.9.20251020"
  canary_is "$CANARY"
}

sc_resize_in_place() {
  local before
  before=$(terraform -chdir="$TF_ROOT" output -raw instance_id)
  export TF_VAR_instance_type=t4g.medium
  quiet ops apply -auto-approve -input=false
  expect "same instance" "$before" terraform -chdir="$TF_ROOT" output -raw instance_id
  expect "resized" t4g.medium node_field type
  canary_is "$CANARY"
}

sc_arch_switch() {
  # Same AMI release, x86_64 image
  export TF_VAR_instance_type=t3.small TF_VAR_ami_name=${DEFAULT_AMI/arm64/x86_64}
  quiet ops apply -auto-approve -input=false
  expect "now x86_64" x86_64 node_field arch
  check "existing data kept" bootstrap_log_has 'Vault state: initialised'
  canary_is "$CANARY"
}

sc_az_move() {
  CANARY="$CANARY-az"   # written just before the move: only the shutdown snapshot has it
  quiet ops vault kv put kv/canary value="$CANARY"
  TF_VAR_subnet_id=$(other_az_subnet); export TF_VAR_subnet_id
  quiet ops apply -auto-approve -input=false
  check "restored from snapshot" bootstrap_log_has 'Vault state: empty,snapshot'
  canary_is "$CANARY"
}

sc_rollback() {
  local good undo
  quiet ops snapshot e2e-good
  good=$(latest_version)
  quiet ops vault kv put kv/canary value=bad-change
  quiet ops restore "$good"
  canary_is "$CANARY"
  undo=$(ops snapshots 5 | awk '/"reason":"pre-restore"/ { print $1; exit }')
  quiet ops restore "$undo"
  canary_is bad-change
  quiet ops vault kv put kv/canary value="$CANARY"
}

sc_snapshot_auth_repair() {
  quiet ops vault delete auth/aws/role/raft-snapshot
  check "snapshots fail without the auth role" snapshot_fails
  check "configure-snapshots repairs it" ops configure-snapshots
  check "configure-snapshots is idempotent" ops configure-snapshots
  check "snapshots work again" ops snapshot e2e-repaired
}

sc_requisite() {
  quiet ops run 'systemctl stop vault'
  check "snapshot service refuses without Vault" snapshot_service_refuses
  expect "Vault stays stopped" inactive vault_state
  quiet ops run 'systemctl start vault'
  check "node ready again" ops wait-ready 300
}

sc_corrupt_snapshot() {
  local good bucket key
  quiet ops snapshot e2e-good
  good=$(latest_version)
  bucket=$(terraform -chdir="$TF_ROOT" output -raw snapshot_bucket)
  key=$(terraform -chdir="$TF_ROOT" output -raw snapshot_object_key)
  disable_node_snapshots   # no shutdown snapshot on top of the corrupt one
  head -c 5000 /dev/urandom >"$TMP/corrupt.snap"
  quiet aws s3api put-object --bucket "$bucket" --key "$key" --body "$TMP/corrupt.snap"
  tf_apply -replace=module.data.aws_ebs_volume.vault_data
  check "cloud-init finished" wait_cloud_init
  check "restore failure detected" bootstrap_log_has 'ERROR: restore failed; Vault stopped'
  check "wait-ready fails fast" wait_ready_fails_fast
  expect "Vault stopped" inactive vault_state
  quiet ops promote "$good"
  quiet ops run "sh -c 'rm -rf /opt/vault/data/* && systemctl start vault && /usr/local/bin/vault-bootstrap.sh'"
  check "node ready after retry" ops wait-ready 300
  canary_is "$CANARY"
}

sc_refusal() {
  local bucket
  bucket=$(terraform -chdir="$TF_ROOT" output -raw snapshot_bucket)
  disable_node_snapshots
  aws s3api list-object-versions --bucket "$bucket" --query '{Objects: Versions[].{Key: Key, VersionId: VersionId}}' \
    --output json >"$TMP/versions.json"
  quiet aws s3api delete-objects --bucket "$bucket" --delete "file://$TMP/versions.json"
  tf_apply -replace=module.data.aws_ebs_volume.vault_data
  check "cloud-init finished" wait_cloud_init
  check "refused to initialise" bootstrap_log_has 'Refusing to initialise a new, empty Vault'
  check "wait-ready fails fast" wait_ready_fails_fast
  check "snapshot timer still enabled" ops run 'systemctl is-enabled vault-snapshot.timer'
  check "override initialises" ops run 'touch /etc/vault.d/allow-new-vault && /usr/local/bin/vault-bootstrap.sh'
  check "override flag removed" ops run '! test -e /etc/vault.d/allow-new-vault'
  check "ready after the override" ops wait-ready 120
  check "snapshots work again" ops snapshot e2e-after-override
}

# A fresh init whose init output can't be stored must discard the new Vault, not keep
# the output anywhere (like the old /root/vault-init.json fallback did).
sc_store_failure() {
  local bucket
  bucket=$(terraform -chdir="$TF_ROOT" output -raw snapshot_bucket)
  # An empty volume and no snapshots: the node refuses (init output already stored),
  # and the override then gets us a fresh init.
  disable_node_snapshots
  aws s3api list-object-versions --bucket "$bucket" --query '{Objects: Versions[].{Key: Key, VersionId: VersionId}}' \
    --output json >"$TMP/versions.json"
  quiet aws s3api delete-objects --bucket "$bucket" --delete "file://$TMP/versions.json"
  tf_apply -replace=module.data.aws_ebs_volume.vault_data
  check "cloud-init finished" wait_cloud_init
  quiet ops run 'chmod -x /usr/local/libexec/vault-node/store-init'   # the store write now fails
  check "init with a failing store write fails" init_with_broken_store_fails
  check "new Vault discarded (stopped, data wiped)" vault_discarded
  check "no init output on disk" no_init_output_on_disk
  check "wait-ready fails fast" wait_ready_fails_fast
  quiet ops run 'chmod +x /usr/local/libexec/vault-node/store-init'
  check "re-run after the fix initialises" ops run 'systemctl start vault && /usr/local/bin/vault-bootstrap.sh'
  check "ready" ops wait-ready 120
}

# --- Run ---------------------------------------------------------------------------------
cleanup() {
  local rc=$?
  if [ -n "${CURRENT:-}" ]; then
    RESULTS+=("| $CURRENT | **FAIL** | $(( (SECONDS - T0) / 60 )) |")
    say "Stopped at $CURRENT: later scenarios depend on it."
  fi
  rm -rf "$TMP"
  if $KEEP; then
    say "Kept the test deployment: TF_WORKSPACE=e2e TF_VAR_name=$TF_VAR_name terraform -chdir=$TF_ROOT destroy"
  else
    say "Destroying the test deployment..."
    terraform -chdir="$TF_ROOT" destroy -auto-approve -input=false >>"$LOG" 2>&1 || say "WARNING: destroy failed, see $LOG"
  fi
  summary
  exit $rc
}

summary() {
  local total=$(( (SECONDS - START) / 60 ))
  cat <<EOF

## $(date -u +%Y-%m-%d) e2e $TIER ($STORE)

- Commit: $(git -C "$REPO" rev-parse --short HEAD)$(git -C "$REPO" diff --quiet HEAD || echo " (with uncommitted changes)")
- Region: ${AWS_REGION:-$(terraform -chdir="$TF_ROOT" console <<<'var.region' 2>/dev/null | tr -d '"')}; default AMI: $DEFAULT_AMI
- Duration: ${total} min; full output: tests/.runs/$(basename "$LOG")

| Scenario | Result | Minutes |
|---|---|---|
$(printf '%s\n' "${RESULTS[@]}")
EOF
}
trap cleanup EXIT

say "e2e $TIER on $STORE ($TF_VAR_name, workspace e2e); log: $LOG"
for sc in $SCENARIOS; do declare -F "sc_$sc" >/dev/null || { echo "unknown scenario: $sc" >&2; exit 1; }; done
for sc in $SCENARIOS; do
  say "== $sc"
  CURRENT=$sc T0=$SECONDS
  # Not in an `if`: that would switch off set -e inside the scenario. A failing
  # check exits the script, and cleanup() records which scenario failed.
  "sc_$sc"
  RESULTS+=("| $sc | PASS | $(( (SECONDS - T0) / 60 )) |")
  CURRENT=
done
