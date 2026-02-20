# Phase 0 Implementation: Multi-Model Selection System

## Status: ✅ COMPLETE

Implementation of intelligent model selection for cost-optimized AI agent orchestration.

## What Was Implemented

### 1. Core Model Selection System

**`Hive.Runtime.ModelSelector`** - Central model selection logic
- Model capability registry mapping models to their strengths
- Intelligent job type → model selection algorithm
- Cost tier tracking (low/medium/high)
- Context limit information per model
- Query functions for model capabilities

**Supported Models:**
- `claude-opus` - Planning, complex implementation, architecture (high cost)
- `claude-sonnet` - General implementation, refactoring (medium cost)
- `claude-haiku` - Research, summarization, verification (low cost)

### 2. Job Classification System

**`Hive.Jobs.Classifier`** - Automatic job type and complexity detection
- Keyword-based classification from job title/description
- Job types: planning, implementation, research, summarization, verification, refactoring, simple_fix
- Complexity levels: simple, moderate, complex
- Automatic model recommendation with reasoning

**Classification Examples:**
- "Plan authentication system" → Planning (complex) → Opus
- "Research caching strategies" → Research → Haiku
- "Fix login bug" → Simple fix → Haiku
- "Implement payment integration" → Implementation (moderate) → Sonnet

### 3. Database Schema Updates

**`Hive.Migrations`** - Schema migration system
- Migration v1: Added multi-model fields to jobs and bees
- Automatic migration on store initialization

**New Job Fields:**
- `job_type` - Classified job type
- `complexity` - Simple/moderate/complex
- `recommended_model` - Auto-recommended model
- `assigned_model` - Actually assigned model
- `model_selection_reason` - Explanation for selection
- `verification_criteria` - List of verification requirements
- `estimated_context_tokens` - Estimated token usage

**New Bee Fields:**
- `assigned_model` - Model this bee is using
- `context_tokens_used` - Current token usage
- `context_tokens_limit` - Model's context limit
- `context_percentage` - Percentage of context used

### 4. Plugin System Updates

**`Hive.Plugin.Model` behaviour** - Extended with new callbacks
- `list_available_models/0` - List all models from provider
- `get_model_info/1` - Get model capabilities and limits
- `get_context_limit/1` - Get context window size

**`Hive.Plugin.Builtin.Models.Claude`** - Updated with multi-model support
- Added Opus, Sonnet, and Haiku model definitions
- Pricing information for all three models
- Context limits (200k for all Claude models)
- Model capability metadata

### 5. Runtime Integration

**`Hive.Jobs.create/1`** - Automatic classification on job creation
- Auto-classifies job type and complexity if not provided
- Recommends optimal model
- Stores classification reasoning

**`Hive.Bees.create_bee_record/2`** - Model assignment on bee spawn
- Reads assigned/recommended model from job
- Stores model in bee record
- Defaults to sonnet if no model specified

**`Hive.Bee.Worker.spawn_process/2`** - Model-specific spawning
- Reads assigned model from bee record
- Passes model to Runtime.Models.spawn_headless
- Model selection happens at spawn time

### 6. Test Coverage

**`test/hive/runtime/model_selector_test.exs`** - 13 tests
- Model selection for all job types
- Complexity-based selection
- Model info queries
- Capability filtering

**`test/hive/jobs/classifier_test.exs`** - 15 tests
- Job type classification
- Complexity detection
- End-to-end classification and recommendation
- Reasoning generation

## How It Works

### Job Creation Flow

```
1. User creates job: "Implement user authentication"
2. Classifier analyzes title/description
3. Classifies as: implementation, moderate complexity
4. Recommends: claude-sonnet
5. Job stored with classification and recommendation
```

### Bee Spawn Flow

```
1. Bee spawned for job
2. Reads job's assigned_model (or recommended_model)
3. Stores model in bee record
4. Spawns Claude with --model flag
5. Bee executes using specified model
```

### Model Selection Examples

| Job Description | Type | Complexity | Model | Reason |
|----------------|------|------------|-------|--------|
| "Plan authentication system" | planning | complex | opus | Complex reasoning required |
| "Research caching strategies" | research | moderate | haiku | Fast, cost-effective analysis |
| "Implement payment API" | implementation | moderate | sonnet | Balanced performance |
| "Fix typo in config" | simple_fix | simple | haiku | Simple task |
| "Verify test coverage" | verification | simple | haiku | Simple checking |
| "Refactor auth module" | refactoring | moderate | sonnet | Code restructuring |

## Cost Optimization

**Expected savings: 40-60% vs. all-Opus approach**

Typical quest breakdown:
- 1 research job (Haiku): $0.10
- 1 planning job (Opus): $2.00
- 3 implementation jobs (Sonnet): $1.50
- 1 verification job (Haiku): $0.05
- **Total: $3.65** vs. **$10.00 all-Opus**

## Files Created

- `lib/hive/runtime/model_selector.ex` - Model selection logic
- `lib/hive/jobs/classifier.ex` - Job classification
- `lib/hive/migrations.ex` - Schema migration system
- `test/hive/runtime/model_selector_test.exs` - Tests
- `test/hive/jobs/classifier_test.exs` - Tests

## Files Modified

- `lib/hive/plugin/model.ex` - Added multi-model callbacks
- `lib/hive/plugin/builtin/models/claude.ex` - Added Opus/Sonnet/Haiku
- `lib/hive/jobs.ex` - Auto-classification on create
- `lib/hive/bees.ex` - Model assignment on spawn
- `lib/hive/bee/worker.ex` - Pass model to spawn
- `lib/hive/store.ex` - Run migrations on init

## Next Steps

Phase 0 is complete and tested. Ready to proceed with:

**Phase 1: Context Management System**
- Context tracking and monitoring
- Automatic handoff at 40-50% usage
- Context compression and summarization

The multi-model foundation is now in place and will enable cost-effective operation throughout all future phases.

## Usage Examples

### Manual Model Override

```elixir
# Create job with specific model
Hive.Jobs.create(%{
  title: "Complex refactor",
  quest_id: "quest-123",
  comb_id: "comb-456",
  assigned_model: "claude-opus"  # Override recommendation
})
```

### Query Model Capabilities

```elixir
# List all models
ModelSelector.list_models()
# => ["claude-opus", "claude-sonnet", "claude-haiku"]

# Get models for research
ModelSelector.models_with_capability(:research)
# => ["claude-haiku"]

# Get cheapest model for a job type
ModelSelector.cheapest_model_for_job(:verification)
# => "claude-haiku"
```

### Check Job Classification

```elixir
# Classify a job description
Classifier.classify_and_recommend(
  "Research best practices for API design",
  "Look into REST, GraphQL, and gRPC patterns"
)
# => %{
#   job_type: :research,
#   complexity: :moderate,
#   recommended_model: "claude-haiku",
#   reason: "Classified as research/analysis task. Moderate complexity."
# }
```
