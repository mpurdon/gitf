# Hive Enhancement Plan: Claude Code Replacement

**Goal**: Transform The Hive into an intelligent, self-verifying multi-agent system that excels at research, planning, and implementation while maintaining strict context budgets and working seamlessly with brownfield projects.

## Core Requirements

1. **Research → Plan → Implement workflow** - Structured phases with clear handoffs
2. **Context budget enforcement** - Never exceed 40-50% context usage per agent
3. **Verification-driven completion** - Drone validates all work before marking complete
4. **Brownfield-ready** - Zero-config onboarding for existing projects

---

## Phase 0: Multi-Model Selection System

**Priority**: Critical - Foundation for cost optimization  
**Estimated effort**: 2-3 days

### 0.1 Model Capability Registry

**New module**: `Hive.Runtime.ModelSelector`

**Responsibilities:**
- Define model capabilities and cost tiers
- Select optimal model for job type
- Track model performance per task type
- Provide model recommendations

**Model capability mapping:**
```elixir
@model_capabilities %{
  # Claude models
  "claude-opus" => %{
    capabilities: [:planning, :complex_implementation, :architecture],
    cost_tier: :high,
    context_limit: 200_000,
    strengths: ["complex reasoning", "large refactors", "system design"]
  },
  "claude-sonnet" => %{
    capabilities: [:implementation, :refactoring, :debugging],
    cost_tier: :medium,
    context_limit: 200_000,
    strengths: ["balanced performance", "general coding", "moderate complexity"]
  },
  "claude-haiku" => %{
    capabilities: [:research, :summarization, :simple_fixes, :verification],
    cost_tier: :low,
    context_limit: 200_000,
    strengths: ["fast responses", "simple tasks", "analysis"]
  }
}
```

**Implementation tasks:**
- [ ] Create `ModelSelector` module
- [ ] Define capability registry with cost tiers
- [ ] Implement job type → model mapping
- [ ] Add model selection logic
- [ ] Create model recommendation API

### 0.2 Job Type Classification

**Database schema additions:**
```sql
ALTER TABLE jobs ADD COLUMN job_type TEXT; -- 'planning', 'implementation', 'research', 'summarization', 'verification', 'refactoring'
ALTER TABLE jobs ADD COLUMN recommended_model TEXT;
ALTER TABLE jobs ADD COLUMN assigned_model TEXT;
ALTER TABLE jobs ADD COLUMN model_selection_reason TEXT;
```

**Job type definitions:**
- **Planning**: Breaking down requirements, designing approach → Opus
- **Implementation**: Writing new code, complex logic → Opus/Sonnet
- **Research**: Analyzing codebase, gathering context → Haiku
- **Summarization**: Compressing context, creating reports → Haiku
- **Verification**: Checking work, running tests → Haiku
- **Refactoring**: Restructuring existing code → Sonnet
- **Simple fixes**: Bug fixes, small changes → Haiku/Sonnet

**Implementation tasks:**
- [ ] Add job type field to `Hive.Schema.Job`
- [ ] Create job type classification logic
- [ ] Add model recommendation to job creation
- [ ] Store model selection reasoning

### 0.3 Queen Model Selection

**Enhance**: `Hive.Queen.Planner`

**New behavior:**
- Classify each job by type during planning phase
- Recommend optimal model per job
- Consider cost budget when selecting models
- Balance quality vs. cost

**Selection algorithm:**
```elixir
def select_model_for_job(job) do
  case job.job_type do
    :planning -> "claude-opus"
    :implementation when job.complexity == :complex -> "claude-opus"
    :implementation -> "claude-sonnet"
    :research -> "claude-haiku"
    :summarization -> "claude-haiku"
    :verification -> "claude-haiku"
    :refactoring -> "claude-sonnet"
    :simple_fix -> "claude-haiku"
  end
end
```

**Implementation tasks:**
- [ ] Add job type classification to planning phase
- [ ] Implement model selection algorithm
- [ ] Add cost estimation per model choice
- [ ] Include model selection in plan output
- [ ] Allow manual model override

### 0.4 Bee Model Assignment

**Enhance**: `Hive.Bee.Spawner`

**New behavior:**
- Spawn bee with job's recommended model
- Pass model-specific configuration
- Track which model was used
- Support model switching mid-quest if needed

**Implementation tasks:**
- [ ] Update bee spawn to accept model parameter
- [ ] Pass model to `Hive.Runtime.Models`
- [ ] Store assigned model in bee record
- [ ] Add model info to bee status
- [ ] Support model override via CLI

### 0.5 Model Performance Tracking

**Database schema additions:**
```sql
CREATE TABLE model_performance (
  id INTEGER PRIMARY KEY,
  model_name TEXT NOT NULL,
  job_type TEXT NOT NULL,
  job_id INTEGER NOT NULL,
  success BOOLEAN NOT NULL,
  tokens_used INTEGER,
  cost_usd REAL,
  duration_seconds INTEGER,
  quality_score REAL, -- from verification results
  recorded_at TIMESTAMP NOT NULL,
  FOREIGN KEY (job_id) REFERENCES jobs(id)
);
```

**New module**: `Hive.Analytics.ModelPerformance`

**Responsibilities:**
- Track model performance per job type
- Calculate success rates and costs
- Identify optimal model choices
- Provide performance reports

**Implementation tasks:**
- [ ] Create `ModelPerformance` schema
- [ ] Record model usage after job completion
- [ ] Calculate quality scores from verification
- [ ] Add performance analytics queries
- [ ] Create `hive models performance` CLI command

### 0.6 Cost-Aware Model Selection

**Enhance**: `Hive.Queen.Planner`

**New behavior:**
- Consider quest budget when selecting models
- Optimize for cost/quality tradeoff
- Suggest model downgrades if over budget
- Warn if quest requires expensive models

**Cost optimization strategies:**
```elixir
# If budget is tight, prefer cheaper models
def optimize_for_budget(jobs, remaining_budget) do
  estimated_cost = calculate_total_cost(jobs)
  
  if estimated_cost > remaining_budget do
    # Downgrade non-critical jobs to cheaper models
    downgrade_models(jobs, target: remaining_budget)
  else
    jobs
  end
end
```

**Implementation tasks:**
- [ ] Add budget consideration to model selection
- [ ] Implement cost optimization logic
- [ ] Add budget warnings to planning phase
- [ ] Allow user to approve/modify model choices
- [ ] Show cost breakdown by model in plan

### 0.7 Multi-Model Provider Support

**Enhance**: `Hive.Plugin.Model` behaviour

**New callbacks:**
```elixir
@callback list_available_models() :: [String.t()]
@callback get_model_capabilities(model :: String.t()) :: map()
@callback get_model_cost(model :: String.t()) :: {:ok, %{input: float(), output: float()}} | :error
```

**Implementation tasks:**
- [ ] Add model listing to plugin behaviour
- [ ] Update each model plugin with available models
- [ ] Add capability metadata per model
- [ ] Add cost information per model
- [ ] Support cross-provider model selection

### 0.8 CLI Enhancements

**New commands:**
```bash
hive models list                    # List available models and capabilities
hive models recommend --job-type X  # Get model recommendation
hive models performance             # Show model performance stats
hive bee spawn --model opus         # Override model selection
hive quest plan --optimize-cost     # Optimize plan for cost
```

**Implementation tasks:**
- [ ] Add model management commands
- [ ] Add model override flags
- [ ] Add cost optimization flags
- [ ] Update help text with model info

---

## Phase 1: Context Management System (Foundation)

**Priority**: Critical - Enables all other features  
**Estimated effort**: 3-5 days

### 1.1 Context Tracking Infrastructure

**Database schema additions:**
```sql
-- Add to existing bee_sessions table
ALTER TABLE bee_sessions ADD COLUMN context_tokens_used INTEGER DEFAULT 0;
ALTER TABLE bee_sessions ADD COLUMN context_tokens_limit INTEGER;
ALTER TABLE bee_sessions ADD COLUMN context_percentage REAL;

-- New table for context snapshots
CREATE TABLE context_snapshots (
  id INTEGER PRIMARY KEY,
  bee_id INTEGER NOT NULL,
  snapshot_at TIMESTAMP NOT NULL,
  tokens_used INTEGER NOT NULL,
  percentage REAL NOT NULL,
  content_summary TEXT,
  FOREIGN KEY (bee_id) REFERENCES bees(id)
);
```

**Implementation tasks:**
- [ ] Add context tracking fields to `Hive.Schema.Bee`
- [ ] Create `Hive.Schema.ContextSnapshot` schema
- [ ] Add migration for new fields and table

### 1.2 Context Monitor Module

**New module**: `Hive.Runtime.ContextMonitor`

```elixir
defmodule Hive.Runtime.ContextMonitor do
  @context_warning_threshold 0.40
  @context_critical_threshold 0.50
  
  # Track context usage from model provider responses
  def record_usage(bee_id, input_tokens, output_tokens)
  
  # Check if bee needs handoff
  def needs_handoff?(bee_id)
  
  # Get current context percentage
  def get_usage_percentage(bee_id)
  
  # Create context snapshot for handoff
  def create_snapshot(bee_id)
end
```

**Implementation tasks:**
- [ ] Create `ContextMonitor` module with usage tracking
- [ ] Integrate with `Hive.Runtime.Models` to capture token counts
- [ ] Add context percentage calculation based on model limits
- [ ] Implement warning/critical threshold checks
- [ ] Add PubSub events for context warnings

### 1.3 Automatic Handoff System

**Enhance existing**: `Hive.Handoff`

**New functionality:**
- Automatic handoff trigger at 45% context usage
- Context compression: summarize completed work
- Preserve only essential context for new session
- Seamless session continuation

**Implementation tasks:**
- [ ] Add automatic handoff detection in `Bee.Worker`
- [ ] Implement context summarization (use Queen to compress)
- [ ] Create handoff context template with essentials only
- [ ] Test handoff preserves task continuity
- [ ] Add handoff metrics to dashboard

### 1.4 Model Provider Context Limits

**Update**: `Hive.Plugin.Model` behaviour

Add callback for context limits:
```elixir
@callback get_context_limit() :: integer()
```

**Implementation tasks:**
- [ ] Add context limit to each model plugin (Claude: 200k, etc.)
- [ ] Update `Hive.Runtime.Models` to expose limits
- [ ] Configure per-model handoff thresholds

---

## Phase 2: Research → Plan → Implement Pipeline

**Priority**: High - Core workflow improvement  
**Estimated effort**: 5-7 days

### 2.1 Quest Phases

**Database schema additions:**
```sql
-- Add phase tracking to quests
ALTER TABLE quests ADD COLUMN current_phase TEXT DEFAULT 'research';
ALTER TABLE quests ADD COLUMN research_summary TEXT;
ALTER TABLE quests ADD COLUMN implementation_plan TEXT;

-- Track phase transitions
CREATE TABLE quest_phase_transitions (
  id INTEGER PRIMARY KEY,
  quest_id INTEGER NOT NULL,
  from_phase TEXT,
  to_phase TEXT NOT NULL,
  transitioned_at TIMESTAMP NOT NULL,
  trigger TEXT, -- 'manual', 'automatic', 'queen_decision'
  FOREIGN KEY (quest_id) REFERENCES quests(id)
);
```

**Implementation tasks:**
- [ ] Add phase fields to `Hive.Schema.Quest`
- [ ] Create `Hive.Schema.QuestPhaseTransition` schema
- [ ] Add migration for phase tracking

### 2.2 Research Phase

**New module**: `Hive.Queen.Research`

**Responsibilities:**
- Analyze codebase structure and patterns
- Identify relevant files, modules, dependencies
- Understand existing architecture
- Document constraints and requirements
- Generate research summary
- **Cache research results per comb**

**Implementation tasks:**
- [ ] Create `Queen.Research` module
- [ ] Implement codebase analysis prompts for Queen
- [ ] Add file tree analysis with relevance scoring
- [ ] Integrate with LSP for symbol discovery (if available)
- [ ] Generate structured research output (JSON/markdown)
- [ ] Store research summary in quest record
- [ ] **Cache research in comb metadata table**
- [ ] **Add incremental research updates**
- [ ] Add `hive quest research <id>` CLI command

**Research output format:**
```json
{
  "codebase_structure": {
    "entry_points": ["lib/hive/application.ex"],
    "key_modules": ["Hive.Queen", "Hive.Bee.Worker"],
    "patterns": ["OTP supervision", "GenServer state machines"]
  },
  "dependencies": ["phoenix_pubsub", "ecto_sqlite3"],
  "constraints": ["Must maintain backward compatibility"],
  "relevant_files": [
    {"path": "lib/hive/queen.ex", "relevance": 0.95, "reason": "Core coordinator"}
  ]
}
```

### 2.2.1 Research Caching System

**Database schema additions:**
```sql
CREATE TABLE comb_research_cache (
  id INTEGER PRIMARY KEY,
  comb_id INTEGER NOT NULL,
  research_version INTEGER NOT NULL DEFAULT 1,
  git_commit_hash TEXT NOT NULL, -- Track which commit was analyzed
  research_data TEXT NOT NULL, -- JSON research output
  created_at TIMESTAMP NOT NULL,
  expires_at TIMESTAMP, -- Optional TTL
  FOREIGN KEY (comb_id) REFERENCES combs(id)
);

CREATE INDEX idx_comb_research_current ON comb_research_cache(comb_id, research_version DESC);

-- Track which files were analyzed
CREATE TABLE research_file_index (
  id INTEGER PRIMARY KEY,
  research_cache_id INTEGER NOT NULL,
  file_path TEXT NOT NULL,
  file_hash TEXT NOT NULL, -- Git blob hash
  relevance_score REAL,
  summary TEXT,
  symbols TEXT, -- JSON array of functions/classes
  FOREIGN KEY (research_cache_id) REFERENCES comb_research_cache(id)
);

CREATE INDEX idx_research_files ON research_file_index(research_cache_id, file_path);
```

**New module**: `Hive.Research.Cache`

```elixir
defmodule Hive.Research.Cache do
  # Get cached research for a comb
  def get_research(comb_id)
  
  # Check if research is still valid (no significant git changes)
  def is_valid?(comb_id)
  
  # Store new research results
  def store_research(comb_id, research_data, git_commit)
  
  # Incrementally update research when files change
  def update_research(comb_id, changed_files)
  
  # Invalidate cache (e.g., after major refactor)
  def invalidate(comb_id)
  
  # Get research for specific files only
  def get_file_research(comb_id, file_paths)
end
```

**Implementation tasks:**
- [ ] Create research cache tables
- [ ] Create `Research.Cache` module
- [ ] Implement cache validation (check git diff)
- [ ] Add incremental update logic
- [ ] Store file-level research for granular reuse
- [ ] Add cache invalidation triggers

### 2.2.2 Research Reuse Strategy

**Cache validation logic:**
```elixir
def is_research_valid?(comb_id) do
  cache = get_latest_cache(comb_id)
  current_commit = Git.current_commit(comb.path)
  
  cond do
    # No cache exists
    is_nil(cache) -> false
    
    # Cache expired (optional TTL)
    cache_expired?(cache) -> false
    
    # Major changes since cache (>20% of files changed)
    major_changes?(cache.git_commit_hash, current_commit) -> false
    
    # Cache is valid
    true -> true
  end
end
```

**Incremental update strategy:**
```elixir
def update_research_if_needed(comb_id) do
  cache = get_latest_cache(comb_id)
  changed_files = Git.changed_files_since(cache.git_commit_hash)
  
  if length(changed_files) < 10 do
    # Small changes: update only affected files
    update_file_research(cache.id, changed_files)
  else
    # Large changes: full re-research
    invalidate(comb_id)
    :needs_full_research
  end
end
```

**Implementation tasks:**
- [ ] Implement git diff analysis
- [ ] Add change threshold detection
- [ ] Create incremental update logic
- [ ] Add smart cache invalidation

### 2.2.3 Bee Context Injection

**New module**: `Hive.Bee.ContextBuilder`

**Responsibilities:**
- Build focused context for each bee from cached research
- Include only relevant files/modules for the job
- Inject research summary without re-analyzing
- Keep context minimal (target: <20% of limit)

```elixir
defmodule Hive.Bee.ContextBuilder do
  # Build context for a bee's job
  def build_context(job_id) do
    job = get_job(job_id)
    research = Research.Cache.get_research(job.comb_id)
    
    %{
      # High-level codebase understanding
      architecture_summary: research.codebase_structure,
      
      # Only files relevant to this job
      relevant_files: filter_relevant_files(research, job),
      
      # Dependencies and constraints
      constraints: research.constraints,
      dependencies: research.dependencies,
      
      # Job-specific context
      job_description: job.description,
      verification_criteria: job.verification_criteria
    }
  end
  
  # Filter research to only job-relevant parts
  defp filter_relevant_files(research, job) do
    research.relevant_files
    |> Enum.filter(&relevant_to_job?(&1, job))
    |> Enum.take(10) # Limit to top 10 most relevant
  end
end
```

**Implementation tasks:**
- [ ] Create `ContextBuilder` module
- [ ] Implement relevance filtering
- [ ] Add context size estimation
- [ ] Integrate with bee spawn
- [ ] Test context stays under 20% limit

### 2.2.4 Research Refresh Triggers

**Automatic cache invalidation on:**
- Major git changes (>20% files modified)
- Manual invalidation via CLI
- Cache age exceeds TTL (optional, e.g., 7 days)
- Dependency changes (package.json, mix.exs, etc.)

**Smart refresh on:**
- New quest in same comb: Check if cache valid, use if so
- File changes detected: Incremental update only changed files
- Bee reports "missing context": Flag for research update

**Implementation tasks:**
- [ ] Add file watcher for dependency files
- [ ] Implement automatic invalidation logic
- [ ] Add manual refresh command: `hive comb refresh <name>`
- [ ] Add cache status to `hive comb list`
- [ ] Show cache age and validity in dashboard

### 2.3 Planning Phase

**New module**: `Hive.Queen.Planner`

**Responsibilities:**
- Break down quest into concrete jobs
- Define job dependencies
- Specify verification criteria per job
- Estimate complexity and context requirements
- Generate implementation plan

**Implementation tasks:**
- [ ] Create `Queen.Planner` module
- [ ] Design planning prompt with research context
- [ ] Implement job breakdown with dependencies
- [ ] Add verification criteria to job schema
- [ ] Store implementation plan in quest record
- [ ] Add `hive quest plan <id>` CLI command
- [ ] Validate plan completeness before proceeding

**Job schema additions:**
```sql
ALTER TABLE jobs ADD COLUMN verification_criteria TEXT; -- JSON array
ALTER TABLE jobs ADD COLUMN estimated_context_tokens INTEGER;
ALTER TABLE jobs ADD COLUMN complexity TEXT; -- 'simple', 'moderate', 'complex'
```

**Plan output format:**
```json
{
  "jobs": [
    {
      "title": "Add context tracking to Bee schema",
      "description": "...",
      "dependencies": [],
      "verification_criteria": [
        "Migration runs successfully",
        "Schema has context_tokens_used field",
        "Tests pass"
      ],
      "estimated_tokens": 15000,
      "complexity": "simple",
      "files_to_modify": ["lib/hive/schema/bee.ex"]
    }
  ],
  "execution_order": [1, 2, 3],
  "estimated_total_tokens": 45000
}
```

### 2.4 Implementation Phase

**Enhance existing**: `Hive.Queen` orchestration

**Changes:**
- Only spawn bees after research + planning complete
- Pass research summary and job context to each bee
- Include verification criteria in bee instructions
- Monitor context usage during implementation

**Implementation tasks:**
- [ ] Add phase gate checks in Queen before spawning bees
- [ ] Update bee spawn to include research context
- [ ] Add verification criteria to bee instructions
- [ ] Implement "focused context" - only relevant files
- [ ] Add phase transition logic in Queen
- [ ] Update `hive queen` to support phased workflow

### 2.5 Phase Transition Logic

**New module**: `Hive.Quest.PhaseManager`

```elixir
defmodule Hive.Quest.PhaseManager do
  # Check if ready to move to next phase
  def can_transition?(quest_id, to_phase)
  
  # Execute phase transition
  def transition(quest_id, to_phase, opts \\ [])
  
  # Get phase requirements
  def phase_requirements(phase)
end
```

**Phase gates:**
- Research → Planning: Research summary exists and is non-empty
- Planning → Implementation: Plan exists with ≥1 job, all jobs have verification criteria
- Implementation → Complete: All jobs verified by Drone

**Implementation tasks:**
- [ ] Create `PhaseManager` module
- [ ] Implement phase gate validation
- [ ] Add automatic transition triggers
- [ ] Record phase transitions in database
- [ ] Add manual phase override for Queen

---

## Phase 3: Verification Drone

**Priority**: High - Quality assurance  
**Estimated effort**: 4-6 days

### 3.1 Verification Framework

**Database schema additions:**
```sql
CREATE TABLE verifications (
  id INTEGER PRIMARY KEY,
  job_id INTEGER NOT NULL,
  bee_id INTEGER NOT NULL,
  status TEXT NOT NULL, -- 'pending', 'passed', 'failed'
  started_at TIMESTAMP,
  completed_at TIMESTAMP,
  verification_report TEXT, -- JSON
  FOREIGN KEY (job_id) REFERENCES jobs(id),
  FOREIGN KEY (bee_id) REFERENCES bees(id)
);

CREATE TABLE verification_checks (
  id INTEGER PRIMARY KEY,
  verification_id INTEGER NOT NULL,
  check_type TEXT NOT NULL, -- 'criteria', 'tests', 'lint', 'build', 'regression'
  status TEXT NOT NULL,
  output TEXT,
  FOREIGN KEY (verification_id) REFERENCES verifications(id)
);
```

**Implementation tasks:**
- [ ] Create `Hive.Schema.Verification` schema
- [ ] Create `Hive.Schema.VerificationCheck` schema
- [ ] Add migration for verification tables

### 3.2 Drone Verification Module

**New module**: `Hive.Drone.Verifier`

**Responsibilities:**
- Detect when bee marks job as complete
- Run verification checks against criteria
- Execute validation commands (tests, lint, build)
- Check for regressions (compare with main branch)
- Generate verification report
- Notify Queen of results

**Implementation tasks:**
- [ ] Create `Drone.Verifier` module
- [ ] Subscribe to bee completion events via PubSub
- [ ] Implement criteria verification (parse and check)
- [ ] Add validation command execution
- [ ] Implement regression detection (git diff analysis)
- [ ] Generate structured verification report
- [ ] Send verification results to Queen via waggle
- [ ] Add `hive verify <bee_id>` CLI command

**Verification report format:**
```json
{
  "job_id": 123,
  "bee_id": 456,
  "status": "passed",
  "checks": [
    {
      "type": "criteria",
      "criterion": "Migration runs successfully",
      "status": "passed",
      "evidence": "mix ecto.migrate output: OK"
    },
    {
      "type": "tests",
      "status": "passed",
      "output": "42 tests, 0 failures"
    },
    {
      "type": "regression",
      "status": "passed",
      "changes": "Only added new fields, no breaking changes"
    }
  ],
  "recommendation": "approve"
}
```

### 3.3 Verification Checks

**Check types to implement:**

1. **Criteria verification** - Match job's verification criteria
2. **Test execution** - Run comb's validation command
3. **Lint checks** - Run linter if configured
4. **Build verification** - Ensure project builds
5. **Regression detection** - Compare with main branch behavior

**Implementation tasks:**
- [ ] Implement criteria parser and matcher
- [ ] Add test execution with timeout
- [ ] Add lint execution (configurable per comb)
- [ ] Add build verification (configurable per comb)
- [ ] Implement regression detection heuristics
- [ ] Make checks configurable per comb

### 3.4 Verification Workflow Integration

**Changes to existing modules:**

**`Hive.Bee.Worker`:**
- Don't auto-mark job as complete
- Mark as "pending_verification" instead
- Wait for Drone verification result

**`Hive.Drone`:**
- Add verification loop to existing health checks
- Process pending verifications
- Update job status based on verification

**`Hive.Queen`:**
- Listen for verification results
- Only mark quest jobs complete after verification passes
- Handle verification failures (retry, reassign, escalate)

**Implementation tasks:**
- [ ] Add "pending_verification" status to jobs
- [ ] Update Bee.Worker to use new status
- [ ] Integrate Verifier into Drone supervision
- [ ] Add verification result handling in Queen
- [ ] Implement verification failure strategies
- [ ] Update dashboard to show verification status

### 3.5 Verification Retry Logic

**New module**: `Hive.Drone.VerificationRetry`

**Strategies for failed verifications:**
1. **Minor issues** - Spawn new bee with failure context
2. **Criteria mismatch** - Refine criteria and re-verify
3. **Persistent failures** - Escalate to Queen for replanning

**Implementation tasks:**
- [ ] Create retry strategy logic
- [ ] Add failure classification
- [ ] Implement automatic retry with context
- [ ] Add escalation to Queen
- [ ] Track retry attempts per job

---

## Phase 4: Brownfield Project Onboarding

**Priority**: Medium - UX improvement  
**Estimated effort**: 3-4 days

### 4.1 Project Discovery

**New module**: `Hive.Comb.Discovery`

**Responsibilities:**
- Detect project type (Elixir, Python, Node, etc.)
- Identify build system and package manager
- Find test commands
- Locate configuration files
- Detect CI/CD setup
- Map project structure

**Implementation tasks:**
- [ ] Create `Comb.Discovery` module
- [ ] Implement language/framework detection
- [ ] Add build system detection (mix, npm, cargo, etc.)
- [ ] Find test commands automatically
- [ ] Detect linter configuration
- [ ] Generate project profile

**Detection heuristics:**
```elixir
# Elixir: mix.exs present
# Node: package.json present
# Python: setup.py, pyproject.toml, requirements.txt
# Rust: Cargo.toml
# etc.
```

### 4.2 Automatic Configuration

**Enhance**: `hive comb add` command

**New behavior:**
- Run discovery on add
- Auto-populate validation command
- Suggest merge strategy based on project
- Set up GitHub integration if `.git/config` has remote
- Create initial codebase map

**Implementation tasks:**
- [ ] Integrate Discovery into `comb add`
- [ ] Auto-configure validation command
- [ ] Add `--auto-configure` flag (default: true)
- [ ] Suggest optimal settings based on project type
- [ ] Store discovery results in comb metadata

### 4.3 Codebase Mapping

**New module**: `Hive.Comb.Mapper`

**Responsibilities:**
- Generate file tree with relevance scores
- Identify entry points
- Map module dependencies
- Create searchable index
- Update map incrementally

**Implementation tasks:**
- [ ] Create `Comb.Mapper` module
- [ ] Implement file tree generation with filtering
- [ ] Add entry point detection per language
- [ ] Create dependency graph (use LSP if available)
- [ ] Store map in comb metadata or separate table
- [ ] Add `hive comb map <name>` CLI command
- [ ] Integrate map into Queen's research phase

**Map output format:**
```json
{
  "entry_points": ["lib/hive/application.ex"],
  "modules": [
    {
      "path": "lib/hive/queen.ex",
      "type": "genserver",
      "exports": ["start_link", "delegate"],
      "dependencies": ["Hive.Schema.Quest", "Hive.Bee.Spawner"]
    }
  ],
  "file_tree": {
    "lib/": {
      "relevance": 1.0,
      "files": ["application.ex", "queen.ex"]
    }
  }
}
```

### 4.4 Quick Start Workflow

**New command**: `hive quick-start`

**Behavior:**
1. Detect if in git repo
2. Initialize hive in parent directory
3. Auto-add current repo as comb
4. Run discovery and mapping
5. Start Queen with "Analyze this project" prompt
6. Generate initial quest suggestions

**Implementation tasks:**
- [ ] Create `quick-start` command
- [ ] Implement auto-detection logic
- [ ] Add guided setup prompts
- [ ] Generate initial analysis quest
- [ ] Provide suggested first quests
- [ ] Update README with quick-start example

### 4.5 Onboarding Documentation

**New file**: `docs/BROWNFIELD_GUIDE.md`

**Content:**
- Quick start for existing projects
- Common project types and configurations
- Troubleshooting discovery issues
- Manual configuration overrides

**Implementation tasks:**
- [ ] Write brownfield onboarding guide
- [ ] Add examples for common frameworks
- [ ] Document discovery process
- [ ] Add troubleshooting section

---

## Phase 5: Integration & Polish

**Priority**: Medium - Tie everything together  
**Estimated effort**: 3-4 days

### 5.1 Queen Intelligence Improvements

**Enhance**: `Hive.Queen` with better decision-making

**Improvements:**
- Use research phase to understand codebase before planning
- Generate more focused, context-efficient job descriptions
- Monitor bee context usage and trigger handoffs
- Respond to verification failures intelligently
- Learn from past quest patterns (optional: store learnings)

**Implementation tasks:**
- [ ] Update Queen prompts with phased workflow
- [ ] Add research context to planning prompts
- [ ] Implement context-aware job sizing
- [ ] Add verification failure response logic
- [ ] Create Queen decision logging

### 5.2 Dashboard Enhancements

**Update**: `Hive.Dashboard` to show new features

**New views:**
- Quest phase visualization (research → plan → implement)
- Context usage meters per bee
- Verification status and reports
- Codebase map visualization
- Phase transition timeline

**Implementation tasks:**
- [ ] Add phase indicator to quest view
- [ ] Create context usage component
- [ ] Add verification results display
- [ ] Build codebase map viewer
- [ ] Add phase timeline component

### 5.3 CLI Improvements

**New commands:**
```bash
hive quest research <id>      # Trigger research phase
hive quest plan <id>          # Trigger planning phase
hive quest implement <id>     # Trigger implementation phase
hive verify <bee_id>          # Manual verification trigger
hive comb map <name>          # Generate codebase map
hive comb refresh <name>      # Refresh research cache
hive quick-start              # Brownfield onboarding
hive context <bee_id>         # Show context usage
hive research status <comb>   # Show research cache status
```

**Implementation tasks:**
- [ ] Add phase management commands
- [ ] Add verification commands
- [ ] Add mapping commands
- [ ] Add context inspection commands
- [ ] Update help text and examples

### 5.4 Testing & Validation

**Test coverage for new features:**

**Unit tests:**
- Context tracking and handoff logic
- Phase transition validation
- Verification check execution
- Discovery and mapping logic

**Integration tests:**
- Full research → plan → implement workflow
- Verification failure and retry
- Automatic handoff during implementation
- Brownfield project onboarding

**E2E tests:**
- Complete quest with verification
- Context budget enforcement
- Multi-bee coordination with verification

**Implementation tasks:**
- [ ] Write unit tests for all new modules
- [ ] Add integration tests for workflows
- [ ] Create E2E test scenarios
- [ ] Add test fixtures for brownfield projects
- [ ] Achieve >80% coverage on new code

### 5.5 Documentation Updates

**Files to update:**
- `README.md` - Add new features and workflow
- `specs/ARCHITECTURE.md` - Document new modules
- `specs/GLOSSARY.md` - Add new terms (phases, verification)
- `specs/DELEGATION.md` - Update with research/planning phases

**New documentation:**
- `docs/CONTEXT_MANAGEMENT.md` - Context budget system
- `docs/VERIFICATION.md` - Verification workflow
- `docs/BROWNFIELD_GUIDE.md` - Onboarding guide
- `docs/PHASES.md` - Research/Plan/Implement details

**Implementation tasks:**
- [ ] Update existing documentation
- [ ] Write new documentation files
- [ ] Add architecture diagrams
- [ ] Create workflow examples
- [ ] Add troubleshooting guides

---

## Implementation Order

**Recommended sequence:**

1. **Phase 0: Multi-Model Selection** (2-3 days)
   - Foundation for intelligent model usage
   - Enables cost optimization from the start
   - Required before spawning bees with different models

2. **Phase 1: Context Management** (3-5 days)
   - Foundation for everything else
   - Prevents context overflow issues
   - Enables better bee management
   - Works with multi-model system

3. **Phase 3: Verification Drone** (4-6 days)
   - Immediate quality improvement
   - Uses Haiku for cost-effective verification
   - Can work with existing workflow
   - Provides feedback loop for Phase 2

4. **Phase 2: Research/Plan/Implement** (5-7 days)
   - Builds on context management
   - Uses verification for quality gates
   - Leverages multi-model selection (Haiku research, Opus planning, Sonnet implementation)
   - Core workflow transformation

5. **Phase 4: Brownfield Onboarding** (3-4 days)
   - Improves UX significantly
   - Uses Haiku for mapping/discovery (cost-effective)
   - Uses mapping in research phase
   - Makes tool more accessible

6. **Phase 5: Integration & Polish** (3-4 days)
   - Ties everything together
   - Improves UI/UX
   - Comprehensive testing

**Total estimated effort**: 20-29 days

---

## Success Metrics

**Multi-Model Selection:**
- ✓ 80%+ of jobs use cost-optimal model
- ✓ Research/summarization uses Haiku (90%+ of time)
- ✓ Complex planning uses Opus when needed
- ✓ Average cost per quest reduced by 40-60% vs. all-Opus

**Context Management:**
- ✓ No bee exceeds 50% context usage
- ✓ Automatic handoffs preserve task continuity
- ✓ Average context usage per bee: 30-40%

**Verification:**
- ✓ 100% of completed jobs verified before marking complete
- ✓ <10% verification failure rate after initial implementation
- ✓ Verification time <2 minutes per job
- ✓ Verification uses Haiku (cost-effective)

**Workflow:**
- ✓ Research phase produces actionable insights (Haiku)
- ✓ Planning phase generates complete, dependency-aware jobs (Opus)
- ✓ Implementation phase completes with <20% rework (Sonnet/Opus)

**Brownfield:**
- ✓ Auto-detection works for 90%+ of common project types
- ✓ Time to first useful quest: <5 minutes
- ✓ Zero manual configuration for standard projects
- ✓ Discovery uses Haiku (cost-effective)

**Overall:**
- ✓ Hive completes multi-job quests with higher quality than Claude Code
- ✓ Users prefer Hive for complex, multi-file changes
- ✓ Context efficiency enables larger, more complex quests
- ✓ Cost per quest 40-60% lower than single-model approach

---

## Risk Mitigation

**Risk: Context tracking inaccurate**
- Mitigation: Test with multiple model providers, add buffer (45% trigger vs 50% limit)

**Risk: Verification too slow**
- Mitigation: Run checks in parallel, make checks optional/configurable

**Risk: Research phase too expensive**
- Mitigation: Cache research results, use cheaper models for analysis

**Risk: Brownfield detection fails**
- Mitigation: Provide manual override, graceful degradation to manual config

**Risk: Phase transitions too rigid**
- Mitigation: Allow manual phase control, add skip/override options

---

## Future Enhancements (Post-MVP)

- **Learning system**: Store successful patterns, improve model selection over time
- **Multi-comb quests**: Coordinate changes across multiple repos
- **Parallel research**: Multiple research bees (Haiku) for large codebases
- **Smart caching**: Reuse research/plans for similar quests
- **Dynamic model switching**: Switch models mid-job based on complexity
- **Cost optimization**: A/B test model choices, learn optimal selections
- **IDE integration**: VSCode extension for in-editor quest creation
- **Collaborative mode**: Multiple humans + multiple AI agents
- **Rollback system**: Automatic rollback on verification failure
- **Model performance learning**: Adjust model selection based on historical success rates

---

## Next Steps

1. Review this plan and adjust priorities
2. Set up project tracking (GitHub issues/project board)
3. Begin Phase 1: Context Management implementation
4. Iterate based on feedback and testing

This plan transforms The Hive into a production-ready Claude Code replacement with superior intelligence, quality assurance, and usability.
