#!/usr/bin/env bash
# Day-2 operations for the Vault node, driven through SSM (no inbound access needed).
#
# usage: scripts/vault-ops.sh [-C <terraform root>] <command> [args]
#
#   run <shell command>   Run a command as root on the node, print its output.
#                         Recorded in SSM Run Command history: never pass secrets.
#   status                Vault version, seal/init state and data mount on the node
#   wait-ready            Wait until the (possibly new) node is initialised and unsealed
#   snapshot [reason]     Take a Raft snapshot now (on the node, uploaded to S3)
#   snapshots [n]         List the n (default 10) most recent snapshot versions in S3
#   restore <version-id>  Roll Vault back to an older snapshot version (takes a
#                         snapshot of the current state first)
#   promote <version-id>  Make an older snapshot version the latest one, i.e. what a
#                         node with an empty data volume restores from
#   apply [tf args]       Snapshot, terraform apply (upgrade, resize, ...), then wait
#                         until the node is ready again and show its status
#   vault <args>          Run the node's own vault CLI as root, e.g. vault kv get kv/foo
#   tf <dir> [tf args]    Terraform in <dir> (e.g. ../vault-config) against Vault, through
#                         a throwaway port forward and with a short-lived root token
#   configure-snapshots   (Re)create the Vault auth the node needs for snapshots
#   logs [-f]             The node's bootstrap log (-f: follow it, Ctrl-C to stop)
#   shell                 Interactive shell on the node (as ssm-user; sudo works)
#   port-forward [port]   Vault on http://127.0.0.1:<port> (default 8200) until Ctrl-C
#
# The Terraform root defaults to the current directory; the region and instance
# come from its outputs.
#
# Requires: terraform, aws (CLI v2), session-manager-plugin, jq, curl
set -euo pipefail

DEPS="terraform aws session-manager-plugin jq curl"

TF_DIR=.
if [ "${1:-}" = "-C" ]; then TF_DIR=$2; shift 2; fi
if [ $# -eq 0 ]; then
  # Print the header comment above as usage text
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit 1
fi

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }

# --- Pre-flight: fail fast, with a hint, before doing anything -------------------
missing=$(for d in $DEPS; do command -v "$d" >/dev/null || printf ' %s' "$d"; done)
if [ -n "$missing" ]; then
  echo "Missing required tools:$missing (see README > Requirements)" >&2
  exit 1
fi
# (with no state at all, terraform output succeeds but prints nothing)
INSTANCE_ID=$(tf_out instance_id 2>/dev/null) || true
if [ -z "$INSTANCE_ID" ]; then
  echo "Nothing deployed in '$TF_DIR' (no instance_id output). Run terraform apply there first," >&2
  echo "or point to the right root with -C <dir>." >&2
  exit 1
fi
export AWS_REGION=${AWS_REGION:-$(tf_out region)}
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "No valid AWS credentials (expired SSO session?). Run: aws sso login${AWS_PROFILE:+ --profile $AWS_PROFILE}" >&2
  exit 1
fi

# --- Talking to the node ------------------------------------------------------------
# Two transports, one rule: if a token goes in or secret data could come out, use
# session(); everything else uses run().
#
#   run()      SSM Run Command: runs as root, reliable exit codes, keeps going if your
#              connection drops, and the command history doubles as an audit trail.
#              But command and output are stored (30 days) and written to the node's disk.
#   session()  SSM session: streamed, nothing stored. Slower to start, and SSM doesn't
#              report exit codes, so session() does that itself.

# Run a shell command on the node through SSM Run Command; print stdout/stderr and
# return its exit code. Output is truncated by SSM at 24 000 characters.
run() {
  local cmd_id status params
  params=$(jq -nc --arg c "$*" '{commands: [$c]}')   # SSM's JSON, with the command safely quoted
  cmd_id=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript --parameters "$params" \
    --query Command.CommandId --output text)
  while :; do
    status=$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
      --query Status --output text 2>/dev/null || echo Pending)
    case $status in Pending|InProgress|Delayed) sleep 2 ;; *) break ;; esac
  done
  # sed: drop the blank lines SSM puts around stdout/stderr
  aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
    --query '[StandardOutputContent, StandardErrorContent]' --output text | sed '/^\s*$/d'
  [ "$status" = Success ]
}

# Run a shell command as root on the node through an SSM session; stream its output
# (stdout and stderr merged) and return its exit code. Nothing is stored.
session() {
  local b64 params rc_file keepalive keepalive_pid rc
  rc_file=$(mktemp)
  # The command travels base64-encoded (no quoting issues), is piped into a root
  # bash, and a marker line reports its exit code (the session always exits 0). The
  # echo before it ends output that has no final newline; awk drops the blank line.
  # { ...; } </dev/null: bash reads the whole command before running it, and
  # nothing in it can read the rest of the script from stdin.
  b64=$(printf '{\n%s\n} </dev/null\n' "$*" | base64 -w0)
  params=$(jq -nc --arg c "sh -c 'echo $b64 | base64 -d | sudo bash; rc=\$?; echo; echo __VAULT_OPS_RC=\$rc'" '{command: [$c]}')
  # The Session Manager plugin ends the session when its stdin closes: keep it open.
  exec {keepalive}< <(sleep 86400); keepalive_pid=$!
  # Also if we're interrupted. Expand now: $keepalive_pid is local.
  # shellcheck disable=SC2064
  trap "kill $keepalive_pid 2>/dev/null || true" EXIT
  aws ssm start-session --target "$INSTANCE_ID" --document-name AWS-StartNonInteractiveCommand \
    --parameters "$params" <&"$keepalive" |
  awk -v rc_file="$rc_file" '
    { sub(/\r$/, "") }
    /^__VAULT_OPS_RC=/ { sub(/^__VAULT_OPS_RC=/, ""); print > rc_file; next }
    /^(Starting|Exiting) session with [Ss]ession[Ii]d/ || /^$/ { next }   # plugin banners
    { print; fflush() }   # line by line, also into a pipe'
  kill "$keepalive_pid" 2>/dev/null || true
  exec {keepalive}<&-
  rc=$(cat "$rc_file"); rm -f "$rc_file"
  return "${rc:-255}"
}

# A random unused local port for a port forward (nothing answers on it).
free_port() {
  local port
  for _ in $(seq 20); do
    port=$((49152 + RANDOM % 16384))
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || { echo "$port"; return 0; }
  done
  echo "No free local port found" >&2
  return 1
}

# Open a throwaway port forward to Vault on a free local port. Sets PF_PORT, and
# PF_PID/PF_OUT for pf_close.
pf_open() {
  PF_PORT=$(free_port) || return 1
  PF_OUT=$(mktemp)
  aws ssm start-session --target "$INSTANCE_ID" --document-name AWS-StartPortForwardingSession \
    --parameters "portNumber=8200,localPortNumber=$PF_PORT" >"$PF_OUT" &
  PF_PID=$!
  # Wait until the port forward accepts connections (a new session can take a
  # while, e.g. right after a restore)
  for _ in $(seq 60); do (exec 3<>"/dev/tcp/127.0.0.1/$PF_PORT") 2>/dev/null && return 0; sleep 1; done
  echo "Port forward to $INSTANCE_ID didn't come up" >&2
  pf_close
  return 1
}

pf_close() {
  local session_id
  [ -n "${PF_PID:-}" ] || return 0
  # The aws CLI runs the Session Manager plugin as a child process: stop both, or the
  # plugin lives on, keeping the port forward (and our stdout/stderr) open.
  pkill -P "$PF_PID" 2>/dev/null || true
  kill "$PF_PID" 2>/dev/null || true
  # Killing them doesn't end the session in SSM (it would stay "Active"): do that too.
  session_id=$(sed -n 's/^Starting session with SessionId: //p' "$PF_OUT" | tr -d '\r')
  [ -z "$session_id" ] || aws ssm terminate-session --session-id "$session_id" >/dev/null 2>&1 || true
  rm -f "$PF_OUT"
  PF_PID=
}

# usage: root_token <display name> <TTL> [wrap TTL]
# Mint a short-lived child of the root token through the open port forward and
# print it, or with a wrap TTL, a wrapping token for it. The root token is read
# with *your* AWS credentials and never leaves this machine. Uses the HTTP API, so no
# local vault CLI needed. Prints nothing on failure.
root_token() {
  local root headers
  # Store-specific read command from the Terraform output
  root=$(bash -c "$(tf_out read_init_command)" | jq -r .root_token)
  headers="X-Vault-Token: $root"
  [ -z "${3:-}" ] || headers+=$'\n'"X-Vault-Wrap-TTL: $3"
  # -H @-: headers from stdin, so the token doesn't show up in the process list
  printf '%s\n' "$headers" |
    curl -sS -H @- -X POST -d "$(jq -nc --arg n "$1" --arg t "$2" '{ttl: $t, renewable: false, display_name: $n}')" \
      "http://127.0.0.1:$PF_PORT/v1/auth/token/create" | jq -r '.wrap_info.token // .auth.client_token // empty'
}

# Mint a short-lived root token and print it response-wrapped: single use, valid for
# 60 s. Only the wrapping token goes to the node (with-root-token unwraps it).
# Called as $(root_wrap), where set -e doesn't apply: errors are checked explicitly.
root_wrap() {
  local wrap
  pf_open || return 1
  wrap=$(root_token vault-ops 15m 60s)
  pf_close
  [ -n "$wrap" ] || { echo "Could not get a token from Vault (is it unsealed? is the stored root token valid?)" >&2; return 1; }
  echo "$wrap"
}

# --- Commands ---------------------------------------------------------------------

status() {
  local bucket object_key latest
  # Expands on the node, not here.
  # shellcheck disable=SC2016
  run 'export VAULT_ADDR=http://127.0.0.1:8200
       echo "instance: $(cloud-init query ds.meta_data.instance-type) $(uname -m) $(rpm -q --qf "%{VERSION}" system-release)"
       vault version
       vault status -format=json | jq -c "{initialized, sealed, version, storage_type}"
       findmnt -no SOURCE,TARGET,FSTYPE /opt/vault/data || echo "/opt/vault/data: not a separate mount"
       echo "bootstrap: $(cat /var/lib/vault-node/bootstrap-done 2>/dev/null || echo "NOT DONE") (cloud-init: $(cloud-init status | sed -n "s/^status: //p"))"
       echo "snapshot timer: $(systemctl is-active vault-snapshot.timer), next run $(systemctl show vault-snapshot.timer -p NextElapseUSecRealtime --value)"
       last=$(systemctl show vault-snapshot.service -p ExecMainStartTimestamp --value)
       # "<result> at <time>", or "none yet" if the timer never fired
       echo "last scheduled snapshot: ${last:+$(systemctl show vault-snapshot.service -p Result --value) at }${last:-none yet}"'
  bucket=$(tf_out snapshot_bucket); object_key=$(tf_out snapshot_object_key)
  latest=$(aws s3api head-object --bucket "$bucket" --key "$object_key" --output json 2>/dev/null) ||
    { echo "latest snapshot in S3: NONE"; return 0; }
  # Age in minutes (jq, so no GNU date needed), reason, and whether this node took it
  jq -r --arg me "$INSTANCE_ID" '
    ((now - (.LastModified | sub("\\+00:00$"; "Z") | fromdateiso8601)) / 60 | floor) as $age
    | "latest snapshot in S3: \($age) min ago (\(.Metadata.reason), "
      + (if .Metadata["instance-id"] == $me then "this node" else "node \(.Metadata["instance-id"])" end) + ")"
      + (if $age > 120 then "  WARNING: older than 2 hours" else "" end)' <<<"$latest"
}

# Ready = the bootstrap finished (its marker exists) and Vault is initialised and
# unsealed. A new node can take a few minutes (SSM registration, install, bootstrap).
# Fails fast, with the end of the bootstrap log, if cloud-init failed before the
# bootstrap succeeded: that node won't become ready without a human.
wait_ready() {
  local deadline=$((SECONDS + ${1:-900})) out
  echo "Waiting for $INSTANCE_ID to be bootstrapped, initialised and unsealed..."
  while [ $SECONDS -lt $deadline ]; do
    # Expands on the node, not here.
    # shellcheck disable=SC2016
    out=$(run 'cloud-init status | sed -n "s/^status: //p"
               test -e /var/lib/vault-node/bootstrap-done && echo bootstrapped || echo pending
               VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json || true' 2>/dev/null) || true
    # Line 1: cloud-init status, line 2: bootstrap marker, then vault status JSON
    if [ "$(sed -n 2p <<<"$out")" = bootstrapped ] &&
       [ "$(sed -n '3,$p' <<<"$out" | jq -r '.initialized and (.sealed | not)' 2>/dev/null)" = true ]; then
      echo "Ready: $(sed -n '3,$p' <<<"$out" | jq -c '{version, cluster_name}')"
      return 0
    fi
    if [ "$(sed -n 1p <<<"$out")" = error ] && [ "$(sed -n 2p <<<"$out")" = pending ]; then
      echo "Bootstrap failed on $INSTANCE_ID. End of /var/log/vault-bootstrap.log:" >&2
      run 'tail -n 15 /var/log/vault-bootstrap.log' >&2 || true
      return 1
    fi
    sleep 10
  done
  echo "Timed out waiting for $INSTANCE_ID" >&2
  return 1
}

snapshots() {
  local bucket object_key
  bucket=$(tf_out snapshot_bucket); object_key=$(tf_out snapshot_object_key)
  printf '%-34s %-26s %9s  %s\n' VERSION_ID LAST_MODIFIED BYTES METADATA
  # Newest n versions of exactly this key (--prefix alone would also match longer keys)
  aws s3api list-object-versions --bucket "$bucket" --prefix "$object_key" \
    --query "Versions[?Key=='$object_key'] | sort_by(@, &LastModified) | reverse(@)[:${1:-10}].[VersionId, LastModified, Size]" \
    --output text |
  while read -r vid modified size; do
    [ "$vid" = None ] && continue
    printf '%-34s %-26s %9s  %s\n' "$vid" "$modified" "$size" \
      "$(aws s3api head-object --bucket "$bucket" --key "$object_key" --version-id "$vid" --query Metadata --output json | jq -c .)"
  done
}

# Roll back to an older snapshot version: save the current state, make the chosen
# version the latest, and restore that on the node with a short-lived root token
# (a restore needs sys/storage/raft/snapshot-force, which the node itself can't do).
restore() {
  local vid=$1 bucket object_key wrap
  bucket=$(tf_out snapshot_bucket); object_key=$(tf_out snapshot_object_key)
  aws s3api head-object --bucket "$bucket" --key "$object_key" --version-id "$vid" \
    --query '{modified: LastModified, metadata: Metadata}' --output json | jq -c '{restoring: .}'
  echo "Saving the current state first, so this restore can be undone:"
  run '/usr/local/bin/vault-snapshot.sh pre-restore'
  promote "$vid"
  wrap=$(root_wrap)
  session "/usr/local/bin/with-root-token $wrap /usr/local/bin/vault-restore.sh"
  echo "Note: the root token and recovery keys are now those valid at the time of the snapshot."
  echo "If the root token was rotated after it, the stored init output no longer matches."
}

promote() {
  local bucket object_key
  bucket=$(tf_out snapshot_bucket); object_key=$(tf_out snapshot_object_key)
  # sed: prefix the new version ID with a readable message
  aws s3api copy-object --bucket "$bucket" --key "$object_key" --copy-source "$bucket/$object_key?versionId=$1" \
    --query VersionId --output text | sed "s/^/Promoted $1 to latest as version /"
}

# Refuse to change the node unless a fresh snapshot is safely in S3: the shutdown
# snapshot also covers replacements, but if it fails nobody notices.
apply() {
  run '/usr/local/bin/vault-snapshot.sh pre-apply' || { echo "Snapshot failed, not applying." >&2; return 1; }
  terraform -chdir="$TF_DIR" apply "$@"
  INSTANCE_ID=$(tf_out instance_id)   # may be a new node now
  wait_ready && status
}

# Terraform for a Vault configuration root (vault-config/), which talks to Vault
# itself: through a port forward, with a short-lived root token, for the duration
# of the run. The token is revoked when Terraform exits; its 1 h TTL only matters
# if that doesn't happen, and leaves room for a slow apply prompt.
tf() {
  local dir
  [ $# -ge 1 ] || { echo "usage: tf <dir> [terraform args]" >&2; return 1; }
  dir=$1; shift
  pf_open
  trap tf_done EXIT
  export VAULT_ADDR=http://127.0.0.1:$PF_PORT
  MINTED_TOKEN=$(root_token terraform 1h)
  [ -n "$MINTED_TOKEN" ] || { echo "Could not get a root token from Vault" >&2; return 1; }
  export VAULT_TOKEN=$MINTED_TOKEN
  terraform -chdir="$dir" "$@"
}

tf_done() {
  # Revoke the root token right away instead of letting it expire
  if [ -n "${MINTED_TOKEN:-}" ]; then
    printf 'X-Vault-Token: %s\n' "$MINTED_TOKEN" |
      curl -sS -H @- -X POST "$VAULT_ADDR/v1/auth/token/revoke-self" >/dev/null || true
  fi
  pf_close
}

case $1 in
  run)        shift; run "$@" ;;
  status)     status ;;
  wait-ready) wait_ready "${2:-900}" ;;
  snapshot)   run "/usr/local/bin/vault-snapshot.sh ${2:-manual}" ;;
  restore)    [ $# -eq 2 ] || { echo "usage: restore <version-id> (see: snapshots)" >&2; exit 1; }
              restore "$2" ;;
  promote)    [ $# -eq 2 ] || { echo "usage: promote <version-id> (see: snapshots)" >&2; exit 1; }
              promote "$2" ;;
  apply)      shift; apply "$@" ;;
  tf)         shift; tf "$@" ;;
  snapshots)  snapshots "${2:-10}" ;;
  configure-snapshots)
              wrap=$(root_wrap)
              session "/usr/local/bin/with-root-token $wrap /usr/local/bin/vault-configure-snapshots.sh" ;;
  logs)       if [ "${2:-}" = -f ]; then
                # Interactive session: it has a terminal on the node, so output streams (the
                # non-interactive one used by session() delivers it at the end) and Ctrl-C
                # reaches tail. Needs a terminal here too.
                exec aws ssm start-session --target "$INSTANCE_ID" --document-name AWS-StartInteractiveCommand \
                  --parameters '{"command": ["sudo tail -n 50 -f /var/log/vault-bootstrap.log"]}'
              else
                run 'tail -n 100 /var/log/vault-bootstrap.log'
              fi ;;
  shell)      exec aws ssm start-session --target "$INSTANCE_ID" ;;
  port-forward)
              echo "Vault on http://127.0.0.1:${2:-8200} (Ctrl-C to stop). In another terminal:"
              echo "  export VAULT_ADDR=http://127.0.0.1:${2:-8200}"
              exec aws ssm start-session --target "$INSTANCE_ID" --document-name AWS-StartPortForwardingSession \
                --parameters "portNumber=8200,localPortNumber=${2:-8200}" ;;
  vault)      shift; wrap=$(root_wrap)
              session "/usr/local/bin/with-root-token $wrap vault $(printf '%q ' "$@")" ;;
  *)          echo "unknown command: $1" >&2; exit 1 ;;
esac
