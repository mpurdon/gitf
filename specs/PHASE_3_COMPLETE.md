# Phase 3 Complete: Verification Drone

## Overview

Phase 3 adds automatic work verification to ensure completed jobs meet quality standards before marking quests as complete.

## Implementation Summary

### Database Schema (Migration v5)

**Jobs collection additions:**
- `verification_status` - "pending", "passed", or "failed"
- `verification_result` - Text output from verification
- `verified_at` - Timestamp of verification

**New collection:**
- `verification_results` - History of all verification runs
  - `id`, `job_id`, `status`, `output`, `exit_code`, `ran_at`

### Core Modules

**Hive.Verification** (`lib/hive/verification.ex`)
- `verify_job/1` - Run verification for a completed job
- `get_verification_status/1` - Check verification status
- `record_result/2` - Store verification results and update job
- `jobs_needing_verification/0` - List unverified completed jobs

**Hive.Drone** (enhanced `lib/hive/drone.ex`)
- Added `check_verifications/0` to patrol cycle
- Automatically verifies completed jobs
- Sends waggle to Queen on verification failures
- Includes verification results in health reports

### CLI Commands

**`hive verify --job <id>`**
- Manually verify a single job
- Shows detailed validation results
- Reports pass/fail status

**`hive verify --quest <id>`**
- Verify all completed jobs in a quest
- Shows summary: X passed, Y failed

**`hive drone --verify`**
- Start drone with automatic verification enabled
- Runs verification checks during patrol cycles

### Integration Points

1. **Job Lifecycle**: Jobs created with `verification_status: "pending"`
2. **Drone Patrol**: Automatically checks for unverified jobs
3. **Comb Validation**: Uses `validation_command` from comb config
4. **Cell Execution**: Runs validation in job's worktree
5. **Queen Notifications**: Sends waggles on verification failures

### Key Features

- **Automatic Verification**: Drone periodically checks completed jobs
- **Manual Verification**: CLI commands for on-demand verification
- **Status Tracking**: Full history of verification attempts
- **Failure Reporting**: Detailed output for failed verifications
- **Quest Blocking**: Can prevent quest completion until all jobs verified

### Test Coverage

**New Tests:**
- 6 tests in `test/hive/verification_test.exs` (from Part 1)
- 2 tests in `test/hive/cli/verify_test.exs`
- Total: 8 new tests, all passing

**Test Scenarios:**
- Verification status tracking
- Result recording
- Pass/fail detection
- Missing cell handling
- Quest-level verification

### Files Created

1. `lib/hive/verification.ex` - Core verification module
2. `test/hive/verification_test.exs` - Verification tests
3. `test/hive/cli/verify_test.exs` - CLI verification tests

### Files Modified

1. `lib/hive/migrations.ex` - Added migration v5
2. `lib/hive/store.ex` - Added verification_results collection
3. `lib/hive/id.ex` - Added :vrf prefix
4. `lib/hive/jobs.ex` - Added verification fields to create
5. `lib/hive/drone.ex` - Added verification patrol
6. `lib/hive/cli.ex` - Added verify command

## Usage Examples

### Manual Verification

```bash
# Verify a single job
hive verify --job job-abc123

# Verify all jobs in a quest
hive verify --quest qst-xyz789
```

### Automatic Verification

```bash
# Start drone with verification enabled
hive drone --verify

# Drone will automatically:
# 1. Check for completed jobs needing verification
# 2. Run validation commands
# 3. Update job status
# 4. Notify Queen of failures
```

### Programmatic Usage

```elixir
# Verify a job
{:ok, :pass, result} = Hive.Verification.verify_job("job-abc123")

# Check verification status
{:ok, status} = Hive.Verification.get_verification_status("job-abc123")

# Record manual verification result
result = %{status: "passed", validations: [], output: "All tests passed"}
{:ok, _} = Hive.Verification.record_result("job-abc123", result)

# List jobs needing verification
jobs = Hive.Verification.jobs_needing_verification()
```

## Architecture

```
Completed Job
     |
     v
Drone Patrol (periodic)
     |
     v
Hive.Verification.verify_job/1
     |
     +-- Get job and comb
     +-- Find cell (worktree)
     +-- Run validation_command
     +-- Parse output
     +-- Update job status
     +-- Store result
     |
     v
Job.verification_status updated
     |
     v
Queen notified (if failed)
```

## Next Steps

Phase 3 is complete. The verification system is operational and integrated with the drone patrol system.

**Remaining Phases:**
- **Phase 4**: Brownfield Onboarding (auto-detect project type, generate codebase maps)
- **Phase 5**: Integration & Polish (dashboard enhancements, CLI improvements, documentation)

## Metrics

- **Lines of Code**: ~200 (minimal implementation)
- **Test Coverage**: 8 tests, 100% passing
- **Integration Points**: 6 modules enhanced
- **CLI Commands**: 2 new commands
- **Database Collections**: 1 new, 1 enhanced
