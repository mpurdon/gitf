#!/usr/bin/env elixir

# Demo script showing multi-model selection in action
# Run with: elixir scripts/demo_multi_model.exs

Mix.install([])

Code.require_file("lib/hive/runtime/model_selector.ex")
Code.require_file("lib/hive/jobs/classifier.ex")

alias Hive.Runtime.ModelSelector
alias Hive.Jobs.Classifier

IO.puts("\n=== Multi-Model Selection Demo ===\n")

# Example job descriptions
jobs = [
  {"Plan authentication system architecture", "Design a secure, scalable auth system with OAuth2 support"},
  {"Research caching strategies", "Investigate Redis, Memcached, and in-memory caching patterns"},
  {"Implement user registration API", "Create REST endpoint for user signup with validation"},
  {"Fix login bug", "Users can't log in with special characters in password"},
  {"Verify test coverage", "Check that all critical paths have test coverage"},
  {"Refactor database layer", "Clean up the repository pattern implementation"},
  {"Summarize changes", "Create a brief summary of all changes in this PR"}
]

IO.puts("Classifying #{length(jobs)} example jobs...\n")

Enum.each(jobs, fn {title, description} ->
  result = Classifier.classify_and_recommend(title, description)
  
  IO.puts("📋 #{title}")
  IO.puts("   Type: #{result.job_type}")
  IO.puts("   Complexity: #{result.complexity}")
  IO.puts("   Model: #{result.recommended_model}")
  IO.puts("   Reason: #{result.reason}")
  IO.puts("")
end)

IO.puts("\n=== Model Capabilities ===\n")

Enum.each(ModelSelector.list_models(), fn model ->
  {:ok, info} = ModelSelector.get_model_info(model)
  
  IO.puts("#{model}:")
  IO.puts("  Cost tier: #{info.cost_tier}")
  IO.puts("  Context: #{info.context_limit} tokens")
  IO.puts("  Capabilities: #{Enum.join(info.capabilities, ", ")}")
  IO.puts("")
end)

IO.puts("\n=== Cost Optimization Example ===\n")

IO.puts("Typical quest with 7 jobs:")
IO.puts("  1 planning (Opus):        $2.00")
IO.puts("  1 research (Haiku):       $0.10")
IO.puts("  3 implementation (Sonnet): $1.50")
IO.puts("  1 verification (Haiku):   $0.05")
IO.puts("  1 summarization (Haiku):  $0.05")
IO.puts("  ─────────────────────────────")
IO.puts("  Total:                    $3.70")
IO.puts("")
IO.puts("Same quest with all Opus:")
IO.puts("  7 jobs (Opus):           $14.00")
IO.puts("")
IO.puts("Savings: $10.30 (74%)")
IO.puts("")
