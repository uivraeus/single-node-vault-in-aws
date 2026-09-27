# Test log

Newest first. Entries from `tests/e2e.sh` are its printed summary, pasted in when worth keeping (a tier passing on a commit that matters, or a failure that taught something). Full output of each run stays in `tests/.runs/` (not committed).

How to run (costs a few cents: small instances for under an hour):

```bash
export AWS_PROFILE=...            # credentials for a lab account
tests/e2e.sh smoke                # ~12 min, secrets-manager root
tests/e2e.sh full                 # ~25 min
tests/e2e.sh --store ps full      # parameter-store root, ~10 min (can run alongside sm)
tests/e2e.sh deploy canary az_move   # single scenarios, in order
```

Tests run in a separate Terraform workspace (`e2e`) with names starting with `vault-e2e-`, and destroy everything at the end, so they never touch a lab deployment in the default workspace.

<!-- New entries below this line -->
