# Test log

Newest first. Entries from `tests/e2e.sh` are its printed summary, pasted in when worth keeping (a tier passing on a commit that matters, or a failure that taught something). Full output of each run stays in `tests/.runs/` (not committed).

How to run (costs a few cents: small instances for under an hour):

```bash
export AWS_PROFILE=...            # credentials for a lab account
tests/e2e.sh smoke                # ~5 min, secrets-manager root
tests/e2e.sh core                 # ~10-15 min
tests/e2e.sh full                 # ~25 min
tests/e2e.sh --store ps full      # parameter-store root, ~10 min (can run alongside sm)
tests/e2e.sh deploy canary az_move   # single scenarios, in order
```

Tests run in a separate Terraform workspace (`e2e`) with names starting with `vault-e2e-`, and destroy everything at the end, so they never touch a lab deployment in the default workspace.

<!-- New entries below this line -->

## 2026-09-30 e2e smoke (sm)

- Commit: 6af2d6d
- Region: eu-north-1; default AMI: al2023-ami-2023.12.20260918.0-kernel-6.12-arm64
- Duration: 4 min; full output: tests/.runs/20260930T184535Z-sm-smoke.log

| Scenario | Result | Minutes |
|---|---|---|
| deploy | PASS | 1 |
| canary | PASS | 0 |
| vault_config | PASS | 0 |
| snapshot | PASS | 0 |

## 2026-09-27 e2e smoke (sm)

- Commit: f115f21
- Region: eu-north-1; default AMI: al2023-ami-2023.12.20260918.0-kernel-6.12-arm64
- Duration: 14 min; full output: tests/.runs/20260927T170629Z-sm-smoke.log

| Scenario | Result | Minutes |
|---|---|---|
| deploy | PASS | 2 |
| canary | PASS | 1 |
| vault_config | PASS | 2 |
| snapshot | PASS | 0 |
| replace_node | PASS | 3 |
| rollback | PASS | 2 |
| snapshot_auth_repair | PASS | 1 |
