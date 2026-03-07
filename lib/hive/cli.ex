defmodule Hive.CLI do
  @moduledoc "Escript entry point. Parses argv and dispatches to subcommand handlers."

  require Logger
  alias Hive.CLI.Format

  # -- Escript entry point ----------------------------------------------------

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    if Hive.Client.remote?() do
      :logger.set_primary_config(:level, :error)
    end

    case extract_cmd_flag(argv) do
      {:cmd, cmd_argv} ->
        # Non-interactive mode: `hive -c <cmd>` or `hive --cmd <cmd>`
        run_cli(cmd_argv)

      :tui ->
        # Interactive mode: launch TUI
        launch_tui()

      {:cli, argv} ->
        # Has subcommands, run classic CLI
        run_cli(argv)
    end
  end

  defp extract_cmd_flag(argv) do
    case argv do
      ["-c" | rest] when rest != [] -> {:cmd, rest}
      ["--cmd" | rest] when rest != [] -> {:cmd, rest}
      [] -> :tui
      _ -> {:cli, argv}
    end
  end

  defp launch_tui do
    File.write("/tmp/hive_tui_debug.log", "launch_tui_entered\n", [:append])

    case ensure_store() do
      :ok ->
        :logger.remove_handler(:default)
        suppress_stderr()

        {:ok, _} = Application.ensure_all_started(:hive)

        File.write("/tmp/hive_tui_debug.log",
          "[#{DateTime.utc_now()}] app started, calling start_queen\n", [:append])

        start_queen()

        Process.flag(:trap_exit, true)
        result = Ratatouille.run(Hive.TUI.App,
          quit_events: [{:key, Ratatouille.Constants.key(:ctrl_c)}]
        )
        File.write("/tmp/hive_tui_debug.log",
          "[#{DateTime.utc_now()}] Ratatouille.run returned: #{inspect(result)}\n", [:append])

        # Check if any exit messages were trapped
        receive do
          {:EXIT, pid, reason} ->
            File.write("/tmp/hive_tui_debug.log",
              "[#{DateTime.utc_now()}] Trapped EXIT from #{inspect(pid)}: #{inspect(reason)}\n", [:append])
        after
          100 -> :ok
        end

      :skip ->
        IO.puts(Hive.CLI.Errors.format_error(:store_not_initialized))
        System.halt(1)
    end
  end

  defp run_cli(argv) do
    argv = expand_defaults(argv)
    optimus = build_optimus!()

    case Optimus.parse(optimus, argv) do
      {:ok, _result} ->
        Optimus.Help.help(optimus, [], 80) |> Enum.each(&IO.puts/1)

      {:ok, subcommand_path, result} ->
        unless Hive.Client.remote?(), do: maybe_ensure_store(subcommand_path)

        if Hive.Client.remote?() do
          case Hive.Client.ping() do
            :ok -> :ok
            {:error, reason} ->
              Format.error("Cannot connect to Hive server at #{Hive.Client.server_url()}. Is it running?")
              Format.error("  #{reason}")
              System.halt(1)
          end
        end

        try do
          dispatch(subcommand_path, result)
        catch
          :return_early -> :ok
        end

      :version ->
        IO.puts("hive #{Hive.version()}")

      :help ->
        Optimus.Help.help(optimus, [], 80) |> Enum.each(&IO.puts/1)

      {:help, subcommand_path} ->
        Optimus.Help.help(optimus, subcommand_path, 80) |> Enum.each(&IO.puts/1)

      {:error, errors} ->
        Enum.each(errors, &Format.error/1)
        System.halt(1)

      {:error, _path, errors} ->
        Enum.each(errors, &Format.error/1)
        System.halt(1)
    end
  end

  # -- Helpers ----------------------------------------------------------------

  # Optimus.ParseResult is a struct that doesn't implement Access, so we
  # cannot use get_in/2 with atom keys.  This helper uses dot-syntax for
  # the struct field and bracket-syntax for the inner map key.
  defp result_get(%Optimus.ParseResult{} = r, section, key) do
    Map.get(Map.get(r, section, %{}), key)
  end

  @quest_subcommands ~w(new list show remove merge report close spec plan start status)

  defp expand_defaults(["quest" | rest]) when rest != [] do
    case rest do
      [sub | _] when sub in @quest_subcommands -> ["quest" | rest]
      # Don't expand flags like --help into "quest new --help"
      [<<"-", _::binary>> | _] -> ["quest" | rest]
      _ -> ["quest", "new" | rest]
    end
  end

  defp expand_defaults(argv), do: argv

  # Commands that manage their own store lifecycle or don't need the store.
  @no_auto_store [[:version], [:server]]

  defp maybe_ensure_store(subcommand_path) do
    unless subcommand_path in @no_auto_store do
      ensure_store()
    end
  end

  defp suppress_stderr do
    # Redirect :standard_error to /dev/null so Elixir range warnings from
    # Ratatouille's renderer don't corrupt the terminal display.
    {:ok, null} = File.open("/dev/null", [:write])
    Process.unregister(:standard_error)
    Process.register(null, :standard_error)
  rescue
    _ -> :ok
  end

  defp start_queen do
    File.write("/tmp/hive_tui_debug.log",
      "[#{DateTime.utc_now()}] start_queen called, hive_dir=#{inspect(Hive.hive_dir())}\n", [:append])

    case Hive.hive_dir() do
      {:ok, root} ->
        # Use GenServer.start (not start_link) so a Queen crash doesn't kill the TUI.
        result = GenServer.start(Hive.Queen, %{hive_root: root}, name: Hive.Queen)
        File.write("/tmp/hive_tui_debug.log",
          "[#{DateTime.utc_now()}] Queen start: #{inspect(result)}\n", [:append])

        case result do
          {:ok, _pid} ->
            Hive.Queen.start_session()

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, _reason} ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp ensure_store do
    case Hive.hive_dir() do
      {:ok, root} ->
        store_dir = Path.join([root, ".hive", "store"])

        case Hive.Store.start_link(data_dir: store_dir) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> Format.error("Store error: #{inspect(reason)}")
        end

      {:error, :not_in_hive} ->
        prompt_init()
    end
  end

  defp prompt_init do
    IO.puts("hive v#{Hive.version()}")
    IO.puts("")
    answer = IO.gets("No hive workspace found. Initialize one here? [y/n] ") |> String.trim() |> String.downcase()

    if answer in ["y", "yes"] do
      case Hive.Init.init(".", force: false) do
        {:ok, expanded} ->
          Format.success("Hive initialized at #{expanded}")
          ensure_store()

        {:error, reason} ->
          Format.error("Init failed: #{inspect(reason)}")
          System.halt(1)
      end
    else
      System.halt(0)
    end
  end

  # -- Command dispatch -------------------------------------------------------
  #
  # Handler modules for each domain. New commands should be added to the
  # appropriate handler module rather than adding more clauses here.
  # Eventually all dispatch/2 clauses will migrate to handler modules.

  @handlers [
    Hive.CLI.QuestHandler,
    Hive.CLI.BeeHandler,
    Hive.CLI.CouncilHandler
  ]

  defp handler_helpers do
    %{
      result_get: &result_get/3,
      resolve_comb_id: &resolve_comb_id/1,
      resolve_comb_name: &resolve_comb_name/1
    }
  end

  defp try_handlers(path, result) do
    helpers = handler_helpers()

    Enum.find_value(@handlers, :not_handled, fn handler ->
      case handler.dispatch(path, result, helpers) do
        :not_handled -> nil
        other -> other
      end
    end)
  end

  # All dispatch/2 clauses are grouped together to satisfy Elixir's
  # clause-grouping requirement. Helper functions follow after.

  defp dispatch([:onboard], result) do
    path = result_get(result, :args, :path)
    name = result_get(result, :options, :name)
    quick = result_get(result, :options, :quick) || false
    preview = result_get(result, :options, :preview) || false
    validation_cmd = result_get(result, :options, :validation_command)

    opts = []
    opts = if name, do: Keyword.put(opts, :name, name), else: opts
    opts = if validation_cmd, do: Keyword.put(opts, :validation_command, validation_cmd), else: opts

    cond do
      preview ->
        case Hive.Onboarding.preview(path) do
          {:ok, info} ->
            Format.info("Project Detection Results:")
            Format.info("  Language: #{info.project_info.language}")
            if info.project_info.framework, do: Format.info("  Framework: #{info.project_info.framework}")
            Format.info("  Build Tool: #{info.project_info.build_tool}")
            if info.project_info.test_framework, do: Format.info("  Test Framework: #{info.project_info.test_framework}")
            Format.info("  Project Type: #{info.project_info.project_type}")
            Format.info("\nSuggested Configuration:")
            Format.info("  Name: #{info.suggestions.name}")
            if info.suggestions.validation_command, do: Format.info("  Validation: #{info.suggestions.validation_command}")
            Format.info("  Merge Strategy: #{info.suggestions.merge_strategy}")
            Format.info("\nFile Counts:")
            Enum.each(info.codebase_map.file_count, fn {ext, count} ->
              Format.info("  #{ext}: #{count} files")
            end)
          {:error, reason} ->
            Format.error("Preview failed: #{reason}")
        end

      quick ->
        Hive.CLI.Progress.with_spinner("Onboarding project...", fn ->
          Hive.Onboarding.quick_onboard(path, opts)
        end)
        |> case do
          {:ok, result} ->
            Format.success("✓ Quick onboarded: #{result.comb.name}")
            Format.info("  Language: #{result.project_info.language}")
            Format.info("  Path: #{result.comb.path}")
            Hive.CLI.Help.show_tip(:comb_added)
          {:error, reason} ->
            Format.error("Onboarding failed: #{reason}")
        end

      true ->
        Hive.CLI.Progress.with_spinner("Analyzing project...", fn ->
          Hive.Onboarding.onboard(path, opts)
        end)
        |> case do
          {:ok, result} ->
            Format.success("✓ Onboarded: #{result.comb.name}")
            Format.info("  Language: #{result.project_info.language}")
            if result.project_info.framework, do: Format.info("  Framework: #{result.project_info.framework}")
            Format.info("  Build Tool: #{result.project_info.build_tool}")
            if result.project_info.validation_command, do: Format.info("  Validation: #{result.project_info.validation_command}")
            Format.info("  Path: #{result.comb.path}")
            Hive.CLI.Help.show_tip(:comb_added)
          {:error, reason} ->
            Format.error("Onboarding failed: #{reason}")
        end
    end
  end

  defp dispatch([:verify], result) do
    job_id = result_get(result, :options, :job)
    quest_id = result_get(result, :options, :quest)

    cond do
      job_id ->
        case Hive.Verification.verify_job(job_id) do
          {:ok, :pass, result} ->
            Format.success("Job #{job_id} verification passed")
            if result[:quality_score] do
              Format.info("  Quality score: #{result.quality_score}/100")
            end
            if result[:security_score] do
              Format.info("  Security score: #{result.security_score}/100")
            end
            if result[:performance_score] do
              Format.info("  Performance score: #{result.performance_score}/100")
            end
          {:ok, :fail, result} ->
            Format.error("Job #{job_id} verification failed")
            if result[:quality_score] do
              Format.warn("  Quality score: #{result.quality_score}/100")
            end
            if result[:security_score] do
              Format.warn("  Security score: #{result.security_score}/100")
            end
            if result[:performance_score] do
              Format.warn("  Performance score: #{result.performance_score}/100")
            end
            if result[:output] && result.output != "" do
              Format.error("  #{result.output}")
            end
          {:error, reason} ->
            Format.error("Verification error: #{inspect(reason)}")
        end

      quest_id ->
        case Hive.Quests.get(quest_id) do
          {:ok, _quest} ->
            jobs = Hive.Jobs.list(quest_id: quest_id)
            results = Enum.map(jobs, fn job ->
              if job.status == "done" do
                case Hive.Verification.verify_job(job.id) do
                  {:ok, status, _} -> {job.id, status}
                  {:error, _} -> {job.id, :error}
                end
              else
                {job.id, :skipped}
              end
            end)
            
            passed = Enum.count(results, fn {_, status} -> status == :pass end)
            failed = Enum.count(results, fn {_, status} -> status == :fail end)
            
            Format.info("Quest #{quest_id} verification: #{passed} passed, #{failed} failed")

          {:error, :not_found} ->
            show_not_found_error(:quest, quest_id)
        end

      true ->
        Format.error("Usage: hive verify --job <id> OR --quest <id>")
    end
  end

  defp dispatch([:quality], result) do
    subcommand = result_get(result, :args, :subcommand)
    
    case subcommand do
      "check" ->
        job_id = result_get(result, :options, :job)
        if job_id do
          reports = Hive.Quality.get_reports(job_id)
          if Enum.empty?(reports) do
            Format.warn("No quality reports for job #{job_id}")
          else
            Enum.each(reports, fn report ->
              Format.info("#{report.analysis_type}: #{report.score}/100 (#{report.tool})")
              if report.issues && length(report.issues) > 0 do
                count = length(report.issues)
                type = case report.analysis_type do
                  "security" -> "findings"
                  "performance" -> "metrics"
                  _ -> "issues"
                end
                Format.warn("  #{count} #{type}")
                
                # Show top 3 items
                report.issues
                |> Enum.take(3)
                |> Enum.each(fn issue ->
                  case report.analysis_type do
                    "performance" ->
                      # Show metric name and value
                      name = Map.get(issue, :name, "")
                      value = Map.get(issue, :value, "")
                      unit = Map.get(issue, :unit, "")
                      Format.info("    • #{name}: #{value} #{unit}")
                    
                    _ ->
                      # Show issue/finding
                      msg = Map.get(issue, :message, "")
                      file = Map.get(issue, :file, "")
                      line = Map.get(issue, :line)
                      if line do
                        Format.warn("    • #{msg} (#{file}:#{line})")
                      else
                        Format.warn("    • #{msg}")
                      end
                  end
                end)
              end
            end)
          end
        else
          Format.error("Usage: hive quality check --job <id>")
        end
      
      "report" ->
        quest_id = result_get(result, :options, :quest)
        if quest_id do
          jobs = Hive.Jobs.list(quest_id: quest_id)
          scores = Enum.map(jobs, fn job ->
            score = Hive.Quality.calculate_composite_score(job.id)
            {job.id, score}
          end)
          
          avg_score = 
            scores
            |> Enum.reject(fn {_, s} -> is_nil(s) end)
            |> Enum.map(fn {_, s} -> s end)
            |> case do
              [] -> nil
              list -> Enum.sum(list) / length(list)
            end
          
          if avg_score do
            Format.info("Quest #{quest_id} average quality: #{Float.round(avg_score, 1)}/100")
          else
            Format.warn("No quality data for quest #{quest_id}")
          end
        else
          Format.error("Usage: hive quality report --quest <id>")
        end
      
      "baseline" ->
        comb_id = result_get(result, :options, :comb)
        job_id = result_get(result, :options, :job)
        
        cond do
          comb_id && job_id ->
            # Set baseline from job's performance report
            reports = Hive.Quality.get_reports(job_id)
            perf_report = Enum.find(reports, &(&1.analysis_type == "performance"))
            
            if perf_report do
              {:ok, _} = Hive.Quality.set_performance_baseline(comb_id, perf_report.issues)
              Format.success("Performance baseline set for comb #{comb_id}")
            else
              Format.error("No performance report found for job #{job_id}")
            end
          
          comb_id ->
            # Show current baseline
            case Hive.Quality.get_performance_baseline(comb_id) do
              nil ->
                Format.warn("No baseline set for comb #{comb_id}")
              
              baseline ->
                Format.info("Performance baseline for comb #{comb_id}:")
                Enum.each(baseline.metrics, fn metric ->
                  Format.info("  • #{metric.name}: #{metric.value} #{metric.unit}")
                end)
            end
          
          true ->
            Format.error("Usage: hive quality baseline --comb <id> [--job <id>]")
        end
      
      "thresholds" ->
        comb_id = result_get(result, :options, :comb)
        
        if comb_id do
          thresholds = Hive.Quality.get_thresholds(comb_id)
          Format.info("Quality thresholds for comb #{comb_id}:")
          Format.info("  • Composite: #{thresholds.composite}/100")
          Format.info("  • Static: #{thresholds.static}/100")
          Format.info("  • Security: #{thresholds.security}/100")
          Format.info("  • Performance: #{thresholds.performance}/100")
        else
          Format.error("Usage: hive quality thresholds --comb <id>")
        end
      
      "trends" ->
        comb_id = result_get(result, :options, :comb)
        
        if comb_id do
          stats = Hive.Quality.get_quality_stats(comb_id)
          
          if stats.total_jobs == 0 do
            Format.warn("No quality data for comb #{comb_id}")
          else
            Format.info("Quality statistics for comb #{comb_id}:")
            Format.info("  • Average: #{stats.average}/100")
            Format.info("  • Min: #{stats.min}/100")
            Format.info("  • Max: #{stats.max}/100")
            Format.info("  • Trend: #{stats.trend}")
            Format.info("  • Total jobs: #{stats.total_jobs}")
            
            IO.puts("")
            Format.info("Recent scores:")
            trends = Hive.Quality.get_quality_trends(comb_id, 5)
            Enum.each(trends, fn t ->
              Format.info("  • #{t.job_id}: #{t.score}/100")
            end)
          end
        else
          Format.error("Usage: hive quality trends --comb <id>")
        end
      
      _ ->
        Format.error("Usage: hive quality <check|report|baseline|thresholds|trends> [options]")
    end
  end

  defp dispatch([:intelligence], result) do
    subcommand = result_get(result, :args, :subcommand)
    
    case subcommand do
      "analyze" ->
        job_id = result_get(result, :options, :job)
        
        if job_id do
          case Hive.Intelligence.analyze_and_suggest(job_id) do
            {:ok, result} ->
              Format.info("Failure Analysis for job #{job_id}:")
              Format.info("  Type: #{result.analysis.failure_type}")
              Format.info("  Cause: #{result.analysis.root_cause}")
              Format.info("  Similar failures: #{result.analysis.similar_count}")
              Format.info("  Recommended strategy: #{result.recommended_strategy}")
              
              IO.puts("")
              Format.info("Suggestions:")
              Enum.each(result.suggestions, fn s ->
                Format.info("  • #{s}")
              end)
            
            {:error, reason} ->
              Format.error("Analysis failed: #{inspect(reason)}")
          end
        else
          Format.error("Usage: hive intelligence analyze --job <id>")
        end
      
      "retry" ->
        job_id = result_get(result, :options, :job)
        
        if job_id do
          case Hive.Intelligence.auto_retry(job_id) do
            {:ok, new_job} ->
              Format.success("Created retry job: #{new_job.id}")
              Format.info("  Strategy: #{new_job.retry_strategy}")
              if new_job.retry_metadata[:note] do
                Format.info("  Note: #{new_job.retry_metadata.note}")
              end
            
            {:error, reason} ->
              Format.error("Retry failed: #{inspect(reason)}")
          end
        else
          Format.error("Usage: hive intelligence retry --job <id>")
        end
      
      "insights" ->
        comb_id = result_get(result, :options, :comb)
        
        if comb_id do
          insights = Hive.Intelligence.get_insights(comb_id)
          
          Format.info("Intelligence Insights for comb #{comb_id}:")
          Format.info("  Total jobs: #{insights.total_jobs}")
          Format.info("  Failed jobs: #{insights.failed_jobs}")
          Format.info("  Success rate: #{insights.success_rate}%")
          
          if insights.top_failure_type do
            Format.info("  Top failure type: #{insights.top_failure_type}")
          end
          
          if length(insights.failure_patterns) > 0 do
            IO.puts("")
            Format.info("Failure Patterns:")
            Enum.each(insights.failure_patterns, fn pattern ->
              Format.warn("  • #{pattern.type}: #{pattern.count} occurrences (#{Float.round(pattern.frequency * 100, 1)}%)")
              if length(pattern.common_causes) > 0 do
                Format.info("    Common causes: #{Enum.join(pattern.common_causes, ", ")}")
              end
            end)
          end
        else
          Format.error("Usage: hive intelligence insights --comb <id>")
        end
      
      "learn" ->
        comb_id = result_get(result, :options, :comb)
        
        if comb_id do
          case Hive.Intelligence.learn(comb_id) do
            {:ok, learning} ->
              Format.success("Learned from #{learning.total_failures} failures")
              Format.info("  Patterns identified: #{length(learning.patterns)}")
            
            {:error, reason} ->
              Format.error("Learning failed: #{inspect(reason)}")
          end
        else
          Format.error("Usage: hive intelligence learn --comb <id>")
        end
      
      "best-practices" ->
        comb_id = result_get(result, :options, :comb)
        
        if comb_id do
          practices = Hive.Intelligence.get_best_practices(comb_id)
          
          if Enum.empty?(practices.common_factors || []) do
            Format.warn("No success patterns found for comb #{comb_id}")
          else
            Format.info("Best Practices for comb #{comb_id}:")
            
            if practices.recommended_model do
              Format.info("  Recommended model: #{practices.recommended_model}")
            end
            
            if practices.average_quality do
              Format.info("  Average quality: #{practices.average_quality}/100")
            end
            
            if length(practices.common_factors) > 0 do
              IO.puts("")
              Format.info("Common Success Factors:")
              Enum.each(practices.common_factors, fn factor ->
                freq = Float.round(factor.frequency * 100, 1)
                Format.info("  • #{factor.factor} (#{freq}%)")
              end)
            end
            
            if length(practices.high_quality_examples || []) > 0 do
              IO.puts("")
              Format.info("High Quality Examples:")
              Enum.each(practices.high_quality_examples, fn job_id ->
                Format.info("  • #{job_id}")
              end)
            end
          end
        else
          Format.error("Usage: hive intelligence best-practices --comb <id>")
        end
      
      "recommend" ->
        comb_id = result_get(result, :options, :comb)
        
        if comb_id do
          recommendation = Hive.Intelligence.recommend_approach(comb_id)
          
          Format.info("Recommended Approach for comb #{comb_id}:")
          Format.info("  Model: #{recommendation.model}")
          Format.info("  Confidence: #{recommendation.confidence}")
          
          if recommendation.quality_expectation do
            Format.info("  Expected quality: #{recommendation.quality_expectation}/100")
          end
          
          IO.puts("")
          Format.info("Suggestions:")
          Enum.each(recommendation.suggestions, fn s ->
            Format.info("  • #{s}")
          end)
        else
          Format.error("Usage: hive intelligence recommend --comb <id>")
        end
      
      _ ->
        Format.error("Usage: hive intelligence <analyze|retry|insights|learn|best-practices|recommend> [options]")
    end
  end

  defp dispatch([:heal], _result) do
    if Hive.Client.remote?() do
      Format.error("This command runs on the server. Run it there directly.")
      return_early()
    end

    Format.info("Running self-healing checks...")
    
    results = Hive.Autonomy.self_heal()
    
    if Enum.empty?(results) do
      Format.success("System healthy, no repairs needed")
    else
      Format.success("Self-healing complete:")
      Enum.each(results, fn {action, count} ->
        Format.info("  • #{action}: #{count}")
      end)
    end
  end

  defp dispatch([:optimize], result) do
    if Hive.Client.remote?() do
      Format.error("This command runs on the server. Run it there directly.")
      return_early()
    end

    comb_id = result_get(result, :options, :comb)
    
    if comb_id do
      # Predict issues
      predictions = Hive.Autonomy.predict_issues(comb_id)
      
      if Enum.empty?(predictions) do
        Format.success("No issues predicted for comb #{comb_id}")
      else
        Format.warn("Predicted Issues for comb #{comb_id}:")
        Enum.each(predictions, fn {type, message} ->
          Format.warn("  • #{type}: #{message}")
        end)
      end
    else
      # Optimize resources
      recommendations = Hive.Autonomy.optimize_resources()
      
      if Enum.empty?(recommendations) do
        Format.success("Resource allocation is optimal")
      else
        Format.info("Resource Optimization Recommendations:")
        Enum.each(recommendations, fn {action, message} ->
          Format.info("  • #{action}: #{message}")
        end)
      end
    end
  end

  defp dispatch([:deadlock], result) do
    if Hive.Client.remote?() do
      Format.error("This command runs on the server. Run it there directly.")
      return_early()
    end

    quest_id = result_get(result, :options, :quest)
    
    if quest_id do
      case Hive.Resilience.detect_deadlock(quest_id) do
        {:ok, :no_deadlock} ->
          Format.success("No deadlock detected in quest #{quest_id}")
        
        {:error, {:deadlock, cycles}} ->
          Format.error("Deadlock detected in quest #{quest_id}!")
          Format.warn("Circular dependencies found:")
          Enum.each(cycles, fn cycle ->
            Format.warn("  • #{Enum.join(cycle, " → ")}")
          end)
          
          IO.puts("")
          Format.info("Attempting to resolve...")
          
          {:ok, :deadlock_resolved} = Hive.Resilience.resolve_deadlock(quest_id, cycles)
          Format.success("Deadlock resolved")
      end
    else
      Format.error("Usage: hive deadlock --quest <id>")
    end
  end

  defp dispatch([:monitor], result) do
    if Hive.Client.remote?() do
      Format.error("This command runs on the server. Run it there directly.")
      return_early()
    end

    action = result_get(result, :args, :action)
    
    case action do
      "start" ->
        interval = result_get(result, :options, :interval) || 60
        Format.info("Starting monitoring (interval: #{interval}s)...")
        Hive.Observability.start_monitoring(interval)
        Format.success("Monitoring started")
      
      "status" ->
        status = Hive.Observability.status()
        
        Format.info("System Status:")
        IO.puts("  Health: #{status.health.status}")
        IO.puts("  Quests: #{status.metrics.quests.active} active, #{status.metrics.quests.completed} completed")
        IO.puts("  Bees: #{status.metrics.bees.active} active")
        IO.puts("  Quality: #{Float.round(status.metrics.quality.average, 1)}")
        IO.puts("  Cost: $#{Float.round(status.metrics.costs.total, 2)}")
        
        if !Enum.empty?(status.alerts) do
          IO.puts("")
          Format.warn("Active Alerts:")
          Enum.each(status.alerts, fn {type, msg} ->
            Format.warn("  • #{type}: #{msg}")
          end)
        end
      
      "metrics" ->
        metrics = Hive.Observability.Metrics.export_prometheus()
        IO.puts(metrics)
      
      "health" ->
        health = Hive.Observability.Health.check()
        IO.puts("Status: #{health.status}")
        Enum.each(health.checks, fn {name, status} ->
          IO.puts("  #{name}: #{status}")
        end)
      
      _ ->
        Format.error("Usage: hive monitor <start|status|metrics|health>")
    end
  end

  defp dispatch([:accept], result) do
    job_id = result_get(result, :options, :job)
    quest_id = result_get(result, :options, :quest)
    
    cond do
      job_id ->
        Format.info("Testing acceptance criteria for job #{job_id}...")
        result = Hive.Acceptance.test_acceptance(job_id)
        
        IO.puts("\nAcceptance Test Results:")
        IO.puts("  Goal Met: #{if result.goal_met, do: "✓", else: "✗"}")
        IO.puts("  In Scope: #{if result.in_scope, do: "✓", else: "✗"}")
        IO.puts("  Minimal: #{if result.is_minimal, do: "✓", else: "✗"}")
        IO.puts("  Quality: #{if result.quality_passed, do: "✓", else: "✗"}")
        IO.puts("")
        
        if result.ready_to_merge do
          Format.success("✓ Ready to merge")
        else
          Format.warn("✗ Not ready to merge")
          IO.puts("\nBlockers:")
          Enum.each(result.blockers, fn blocker ->
            Format.warn("  • #{blocker}")
          end)
        end
      
      quest_id ->
        Format.info("Testing acceptance criteria for quest #{quest_id}...")
        result = Hive.Acceptance.test_quest_acceptance(quest_id)
        
        IO.puts("\nQuest Acceptance:")
        IO.puts("  Goal Achieved: #{if result.goal_achieved, do: "✓", else: "✗"}")
        IO.puts("  Scope Clean: #{if result.scope_clean, do: "✓", else: "✗"}")
        IO.puts("  Simplicity: #{result.simplicity_score}")
        IO.puts("")
        
        if result.ready_to_complete do
          Format.success("✓ Quest ready to complete")
        else
          Format.warn("Recommendation: #{result.recommendation}")
        end
      
      true ->
        Format.error("Usage: hive accept --job <id> OR --quest <id>")
    end
  end

  defp dispatch([:scope], result) do
    job_id = result_get(result, :options, :job)
    quest_id = result_get(result, :options, :quest)
    
    cond do
      job_id ->
        result = Hive.ScopeGuard.check_scope(job_id)
        
        IO.puts("Scope Check for job #{job_id}:")
        IO.puts("  In Scope: #{if result.in_scope, do: "✓", else: "✗"}")
        
        if !Enum.empty?(result.warnings) do
          IO.puts("\nWarnings:")
          Enum.each(result.warnings, fn {type, msg} ->
            Format.warn("  • #{type}: #{msg}")
          end)
        end
        
        IO.puts("\nRecommendation: #{result.recommendation}")
      
      quest_id ->
        result = Hive.ScopeGuard.check_quest_scope(quest_id)
        
        IO.puts("Scope Check for quest #{quest_id}:")
        IO.puts("  Total Jobs: #{result.total_jobs}")
        IO.puts("  Status: #{result.overall_status}")
        
        if !Enum.empty?(result.scope_warnings) do
          IO.puts("\nWarnings:")
          Enum.each(result.scope_warnings, fn {type, msg} ->
            Format.warn("  • #{type}: #{msg}")
          end)
        end
      
      true ->
        Format.error("Usage: hive scope --job <id> OR --quest <id>")
    end
  end

  defp dispatch([:comb, :add], result) do
    path = result_get(result, :args, :path)

    if Hive.Client.remote?() do
      unless path do
        Format.error("Remote mode requires an explicit path. Usage: hive comb add <path>")
        System.halt(1)
      end

      name = result_get(result, :options, :name)
      opts = if name, do: [name: name], else: []

      case Hive.Client.add_comb(path, opts) do
        {:ok, comb} -> Format.success("Comb \"#{comb.name}\" registered (#{comb.id})")
        {:error, reason} -> Format.error("Failed to add comb: #{inspect(reason)}")
      end
    else
      auto = result_get(result, :options, :auto) || false

      path =
        if path do
          path
        else
          case discover_nearby_repos() do
            [] ->
              Format.error("No git repositories found in the current directory.")
              System.halt(1)

            repos ->
              IO.puts("Found git repositories:")

              repos
              |> Enum.with_index(1)
              |> Enum.each(fn {{display, _abs_path}, idx} ->
                IO.puts("  #{idx}) #{display}")
              end)

              IO.puts("")
              answer = IO.gets("Select a repo [1-#{length(repos)}]: ") |> String.trim()

              case Integer.parse(answer) do
                {n, ""} when n >= 1 and n <= length(repos) ->
                  {_display, abs_path} = Enum.at(repos, n - 1)
                  abs_path

                _ ->
                  Format.error("Invalid selection: #{answer}")
                  System.halt(1)
              end
          end
        end

      # If --auto flag is set, use onboarding
      if auto do
        name = result_get(result, :options, :name)
        validation_command = result_get(result, :options, :validation_command)

        opts = []
        opts = if name, do: Keyword.put(opts, :name, name), else: opts
        opts = if validation_command, do: Keyword.put(opts, :validation_command, validation_command), else: opts
        opts = Keyword.put(opts, :skip_research, true)

        case Hive.Onboarding.onboard(path, opts) do
          {:ok, result} ->
            Format.success("Comb \"#{result.comb.name}\" auto-configured (#{result.comb.id})")
            Format.info("  Language: #{result.project_info.language}")
            if result.project_info.framework, do: Format.info("  Framework: #{result.project_info.framework}")
            if result.project_info.validation_command, do: Format.info("  Validation: #{result.project_info.validation_command}")
          {:error, reason} ->
            Format.error("Auto-configuration failed: #{reason}")
        end
      else
        # Original manual configuration
        name = result_get(result, :options, :name)
        merge_strategy = result_get(result, :options, :merge_strategy)
        validation_command = result_get(result, :options, :validation_command)
        github_owner = result_get(result, :options, :github_owner)
        github_repo = result_get(result, :options, :github_repo)

        opts = []
        opts = if name, do: Keyword.put(opts, :name, name), else: opts
        opts = if merge_strategy, do: Keyword.put(opts, :merge_strategy, merge_strategy), else: opts

        opts =
          if validation_command,
            do: Keyword.put(opts, :validation_command, validation_command),
            else: opts

        opts = if github_owner, do: Keyword.put(opts, :github_owner, github_owner), else: opts
        opts = if github_repo, do: Keyword.put(opts, :github_repo, github_repo), else: opts

        case Hive.Comb.add(path, opts) do
          {:ok, comb} ->
            Format.success("Comb \"#{comb.name}\" registered (#{comb.id})")

          {:error, :path_not_found} ->
            Format.error("Path does not exist: #{path}")

          {:error, reason} ->
            Format.error("Failed to add comb: #{inspect(reason)}")
        end
      end
    end
  end

  defp dispatch([:comb, :list], _result) do
    combs =
      if Hive.Client.remote?() do
        case Hive.Client.list_combs() do
          {:ok, c} -> c
          {:error, reason} -> Format.error("Remote error: #{inspect(reason)}"); []
        end
      else
        Hive.Comb.list()
      end

    case combs do
      [] ->
        Format.info("No combs registered. Use `hive comb add <path>` to register one.")

      combs ->
        current_id =
          unless Hive.Client.remote?() do
            case Hive.Comb.current() do
              {:ok, c} -> c.id
              _ -> nil
            end
          end

        headers = ["", "ID", "Name", "Path"]

        rows =
          Enum.map(combs, fn c ->
            marker = if current_id && c.id == current_id, do: "*", else: ""
            [marker, c.id, c.name, c[:path] || c[:repo_url] || "-"]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:comb, :remove], result) do
    name = result_get(result, :args, :name)

    remove_result =
      if Hive.Client.remote?(),
        do: Hive.Client.remove_comb(name),
        else: Hive.Comb.remove(name)

    case remove_result do
      :ok ->
        Format.success("Comb \"#{name}\" removed.")

      {:ok, comb} ->
        Format.success("Comb \"#{comb.name}\" removed.")

      {:error, :not_found} ->
        show_not_found_error(:comb, name)
    end
  end

  defp dispatch([:comb, :use], result) do
    name = result_get(result, :args, :name)

    if Hive.Client.remote?() do
      unless name do
        Format.error("Remote mode requires an explicit name/id. Usage: hive comb use <name>")
        System.halt(1)
      end

      case Hive.Client.use_comb(name) do
        {:ok, comb} -> Format.success("Current comb set to \"#{comb.name}\" (#{comb.id})")
        {:error, :not_found} -> show_not_found_error(:comb, name)
        {:error, reason} -> Format.error("Failed to set current comb: #{inspect(reason)}")
      end
    else
      if name do
        case Hive.Comb.set_current(name) do
          {:ok, comb} ->
            Format.success("Current comb set to \"#{comb.name}\" (#{comb.id})")

          {:error, :not_found} ->
            show_not_found_error(:comb, name)

          {:error, reason} ->
            Format.error("Failed to set current comb: #{inspect(reason)}")
        end
      else
        case Hive.Comb.list() do
          [] ->
            IO.puts(Hive.CLI.Errors.format_error(:no_combs))

          combs ->
            IO.puts("Registered combs:")

            combs
            |> Enum.with_index(1)
            |> Enum.each(fn {c, idx} ->
              IO.puts("  #{idx}) #{c.name} (#{c.id})")
            end)

            IO.puts("")
            answer = IO.gets("Select a comb [1-#{length(combs)}]: ") |> String.trim()

            case Integer.parse(answer) do
              {n, ""} when n >= 1 and n <= length(combs) ->
                comb = Enum.at(combs, n - 1)

                case Hive.Comb.set_current(comb.id) do
                  {:ok, c} ->
                    Format.success("Current comb set to \"#{c.name}\" (#{c.id})")

                  {:error, reason} ->
                    Format.error("Failed: #{inspect(reason)}")
                end

              _ ->
                Format.error("Invalid selection: #{answer}")
            end
        end
      end
    end
  end

  defp dispatch([:comb, :rename], result) do
    name = result_get(result, :args, :name)
    new_name = result_get(result, :args, :new_name)

    case Hive.Comb.rename(name, new_name) do
      {:ok, comb} ->
        Format.success("Comb renamed to \"#{comb.name}\" (#{comb.id})")

      {:error, :not_found} ->
        show_not_found_error(:comb, name)

      {:error, :name_already_taken} ->
        Format.error("A comb named \"#{new_name}\" already exists.")

      {:error, {:rename_failed, reason}} ->
        Format.error("Failed to rename directory: #{inspect(reason)}")

      {:error, reason} ->
        Format.error("Failed to rename comb: #{inspect(reason)}")
    end
  end

  defp dispatch([:waggle, :list], result) do
    to = result_get(result, :options, :to)
    opts = if to, do: [to: to], else: []

    case Hive.Waggle.list(opts) do
      [] ->
        Format.info("No waggle messages found.")

      waggles ->
        headers = ["ID", "From", "To", "Subject", "Read"]

        rows =
          Enum.map(waggles, fn w ->
            [w.id, w.from, w.to, w.subject || "-", if(w.read, do: "yes", else: "no")]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:waggle, :show], result) do
    id = result_get(result, :args, :id)

    case Hive.Store.get(:waggles, id) do
      nil ->
        Format.error("Waggle not found: #{id}")
        Format.info("Hint: use `hive waggle list` to see all messages.")

      waggle ->
        IO.puts("ID:      #{waggle.id}")
        IO.puts("From:    #{waggle.from}")
        IO.puts("To:      #{waggle.to}")
        IO.puts("Subject: #{waggle.subject || "-"}")
        IO.puts("Read:    #{waggle.read}")
        IO.puts("Sent:    #{waggle.inserted_at}")
        IO.puts("")

        if waggle.body do
          IO.puts(waggle.body)
        end
    end
  end

  defp dispatch([:waggle, :send], result) do
    from = result_get(result, :options, :from)
    to = result_get(result, :options, :to)
    subject = result_get(result, :options, :subject)
    body = result_get(result, :options, :body)

    {:ok, waggle} = Hive.Waggle.send(from, to, subject, body)
    Format.success("Waggle sent (#{waggle.id})")
  end

  defp dispatch([:cell, :list], _result) do
    case Hive.Cell.list(status: "active") do
      [] ->
        Format.info("No active cells. Use `hive cell list` after spawning a bee.")

      cells ->
        headers = ["ID", "Bee ID", "Comb ID", "Branch", "Path"]

        rows =
          Enum.map(cells, fn c ->
            [c.id, c.bee_id, c.comb_id, c.branch, c.worktree_path]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:cell, :clean], _result) do
    case Hive.Cell.cleanup_orphans() do
      {:ok, 0} ->
        Format.info("No orphaned cells found.")

      {:ok, count} ->
        Format.success("Marked #{count} orphaned cell(s) as removed.")
    end
  end

  defp dispatch([:prime], result) do
    bee_id = result_get(result, :options, :bee)
    queen? = result_get(result, :flags, :queen) || false

    if Hive.Client.remote?() do
      # In remote mode, prime is a no-op — the bee works without local context injection
      :ok
    else
      cond do
        queen? ->
          do_prime_queen()

        is_binary(bee_id) ->
          do_prime_bee(bee_id)

        true ->
          Format.error("Specify --queen or --bee <id>")
      end
    end
  end

  defp dispatch([:queen], _result) do
    case Hive.hive_dir() do
      {:ok, hive_root} ->
        case Hive.Queen.start_link(hive_root: hive_root) do
          {:ok, _pid} ->
            Hive.Queen.start_session()

            # Print messages BEFORE launching Claude, not after.
            # Once Claude starts, it takes full control of the terminal --
            # any BEAM writes to stdout would corrupt Claude's TUI rendering.
            Format.success("Queen is active at #{hive_root}")

            case Hive.Queen.launch() do
              :ok ->
                :ok

              {:error, reason} ->
                Format.warn("Could not launch Claude: #{inspect(reason)}")
                Format.info("Queen running without Claude. Listening for waggles.")
            end

            Hive.Queen.await_session_end()

          {:error, {:already_started, _pid}} ->
            Format.warn("Queen is already running.")

          {:error, reason} ->
            Format.error("Failed to start Queen: #{inspect(reason)}")
        end

      {:error, :not_in_hive} ->
        IO.puts(Hive.CLI.Errors.format_error(:store_not_initialized))
        Format.info("Hint: use `hive init` or `hive init --quick` to create a workspace.")
    end
  end

  defp dispatch([:bee, :list], _result) do
    bees =
      if Hive.Client.remote?() do
        case Hive.Client.list_bees() do
          {:ok, b} -> b
          {:error, reason} -> Format.error("Remote error: #{inspect(reason)}"); []
        end
      else
        Hive.Bees.list()
      end

    case bees do
      [] ->
        Format.info("No bees. Bees are spawned when the Queen assigns jobs.")

      bees ->
        headers = ["ID", "Name", "Status", "Job ID", "Context %"]

        rows =
          Enum.map(bees, fn b ->
            context_pct =
              case b[:context_percentage] do
                nil -> "-"
                pct when is_number(pct) -> "#{Float.round(pct * 100, 1)}%"
                _ -> "-"
              end

            [b.id, b.name, b.status, b[:job_id] || "-", context_pct]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:bee, :spawn], result) do
    job_id = result_get(result, :options, :job)
    name = result_get(result, :options, :name)

    case resolve_comb_id(result_get(result, :options, :comb)) do
      {:ok, comb_id} ->
        with {:ok, hive_root} <- Hive.hive_dir(),
             {:ok, comb} <- Hive.Comb.get(comb_id) do
          opts = if name, do: [name: name], else: []

          case Hive.Bees.spawn_detached(job_id, comb.id, hive_root, opts) do
            {:ok, bee} ->
              Format.success("Bee \"#{bee.name}\" spawned (#{bee.id})")

            {:error, reason} ->
              Format.error("Failed to spawn bee: #{inspect(reason)}")
          end
        else
          {:error, :not_in_hive} ->
            IO.puts(Hive.CLI.Errors.format_error(:store_not_initialized))

          {:error, :not_found} ->
            show_not_found_error(:comb, comb_id)

          {:error, reason} ->
            Format.error("Failed: #{inspect(reason)}")
        end

      {:error, :no_comb} ->
        Format.error("No comb specified. Use --comb or set one with `hive comb use`.")
    end
  end

  defp dispatch([:bee, :stop], result) do
    bee_id = result_get(result, :options, :id)

    stop_result =
      if Hive.Client.remote?(),
        do: Hive.Client.stop_bee(bee_id),
        else: Hive.Bees.stop(bee_id)

    case stop_result do
      :ok ->
        Format.success("Bee #{bee_id} stopped.")

      {:error, :not_found} ->
        show_not_found_error(:bee, bee_id)
    end
  end

  defp dispatch([:bee, :complete], result) do
    bee_id = result_get(result, :args, :bee_id)

    if Hive.Client.remote?() do
      case Hive.Client.complete_bee(bee_id) do
        :ok -> Format.success("Bee #{bee_id} marked as completed.")
        {:error, reason} -> Format.error("Failed: #{inspect(reason)}")
      end
    else
      case Hive.Bees.get(bee_id) do
        {:ok, bee} ->
          Hive.Store.put(:bees, %{bee | status: "stopped"})

          if bee.job_id do
            Hive.Jobs.complete(bee.job_id)
            Hive.Jobs.unblock_dependents(bee.job_id)

            Hive.Waggle.send(
              bee_id,
              "queen",
              "job_complete",
              "Job #{bee.job_id} completed successfully"
            )
          end

          Format.success("Bee #{bee_id} marked as completed.")

        {:error, _} ->
          show_not_found_error(:bee, bee_id)
      end
    end
  end

  defp dispatch([:bee, :fail], result) do
    bee_id = result_get(result, :args, :bee_id)
    reason = result_get(result, :options, :reason) || "unknown"

    if Hive.Client.remote?() do
      case Hive.Client.fail_bee(bee_id, reason) do
        :ok -> Format.success("Bee #{bee_id} marked as failed: #{reason}")
        {:error, err} -> Format.error("Failed: #{inspect(err)}")
      end
    else
      case Hive.Bees.get(bee_id) do
        {:ok, bee} ->
          Hive.Store.put(:bees, %{bee | status: "crashed"})

          if bee.job_id do
            Hive.Jobs.fail(bee.job_id)
            Hive.Waggle.send(bee_id, "queen", "job_failed", "Job #{bee.job_id} failed: #{reason}")
          end

          Format.success("Bee #{bee_id} marked as failed: #{reason}")

        {:error, _} ->
          show_not_found_error(:bee, bee_id)
      end
    end
  end

  defp dispatch([:bee, :revive], result) do
    dead_bee_id = result_get(result, :args, :bee_id)

    with {:ok, hive_root} <- Hive.hive_dir() do
      case Hive.Bees.revive(dead_bee_id, hive_root) do
        {:ok, bee} ->
          Format.success(
            "Revived into bee \"#{bee.name}\" (#{bee.id}) using #{dead_bee_id}'s worktree"
          )

        {:error, reason} ->
          Format.error("Failed to revive: #{inspect(reason)}")
      end
    else
      {:error, :not_in_hive} ->
        IO.puts(Hive.CLI.Errors.format_error(:store_not_initialized))
    end
  end

  defp dispatch([:bee, :context], result) do
    bee_id = result_get(result, :args, :bee_id)

    case Hive.Runtime.ContextMonitor.get_usage_stats(bee_id) do
      {:ok, stats} ->
        IO.puts("Bee: #{bee_id}")
        IO.puts("Context Usage:")
        IO.puts("  Tokens used:  #{stats.tokens_used}")
        IO.puts("  Tokens limit: #{stats.tokens_limit || "unknown"}")
        IO.puts("  Percentage:   #{Float.round(stats.percentage * 100, 2)}%")
        IO.puts("  Status:       #{stats.status}")
        IO.puts("  Needs handoff: #{stats.needs_handoff}")

        if stats.needs_handoff do
          Format.error("\n⚠️  This bee needs a handoff - context usage is critical!")
        end

      {:error, :not_found} ->
        show_not_found_error(:bee, bee_id)
    end
  end

  defp dispatch([:quest, :report], result) do
    id = result_get(result, :args, :id)

    if Hive.Client.remote?() do
      case Hive.Client.quest_report(id) do
        {:ok, report} -> IO.puts(report[:text] || inspect(report))
        {:error, reason} -> Format.error("Report failed: #{format_error(reason)}")
      end
    else
      case Hive.Report.generate(id) do
        {:ok, report} ->
          IO.puts(Hive.Report.format(report))

        {:error, :not_found} ->
          show_not_found_error(:quest, id)

        {:error, reason} ->
          Format.error("Report failed: #{format_error(reason)}")
      end
    end
  end

  defp dispatch([:quest, :merge], result) do
    id = result_get(result, :args, :id)

    if Hive.Client.remote?() do
      case Hive.Client.quest_merge(id) do
        {:ok, data} -> Format.success("All bee branches merged into #{data[:branch] || "quest branch"}")
        {:error, reason} -> Format.error("Quest merge failed: #{format_error(reason)}")
      end
    else
      case Hive.Merge.merge_quest(id) do
        {:ok, branch} ->
          Format.success("All bee branches merged into #{branch}")

        {:error, :not_found} ->
          show_not_found_error(:quest, id)

        {:error, :no_cells} ->
          Format.error("No active cells to merge for this quest.")

        {:error, {:merge_conflicts, branch, failed}} ->
          Format.warn("Merged into #{branch} with conflicts in: #{Enum.join(failed, ", ")}")

        {:error, reason} ->
          Format.error("Quest merge failed: #{format_error(reason)}")
      end
    end
  end

  defp dispatch([:quest, :close], result) do
    id = result_get(result, :args, :id)

    close_result =
      if Hive.Client.remote?(),
        do: Hive.Client.close_quest(id),
        else: Hive.Quests.close(id)

    case close_result do
      {:ok, quest} ->
        Format.success("Quest \"#{quest.name}\" closed. Associated cells removed.")

      {:error, :not_found} ->
        show_not_found_error(:quest, id)
    end
  end

  defp dispatch([:quest, :new], result) do
    goal = result_get(result, :args, :goal)

    if Hive.Client.remote?() do
      comb_opt = result_get(result, :options, :comb)
      attrs = if comb_opt, do: %{goal: goal, comb_id: comb_opt}, else: %{goal: goal}

      case Hive.Client.create_quest(attrs) do
        {:ok, quest} ->
          Format.success("Quest \"#{quest.name}\" created (#{quest.id})")
          Format.info("Starting quest execution on remote server...")

          case Hive.Client.start_quest(quest.id) do
            {:ok, data} ->
              phase = if is_map(data), do: data[:phase], else: data
              Format.success("Quest #{quest.id} is now in #{phase} phase.")

            {:error, reason} ->
              Format.warn("Could not auto-start: #{inspect(reason)}")
          end

        {:error, reason} ->
          Format.error("Failed to create quest: #{inspect(reason)}")
      end
    else
      goal = if goal == nil or goal == "" do
        answer = IO.gets("What do you want to build? ") |> String.trim()
        if answer == "", do: System.halt(0), else: answer
      else
        goal
      end

      quest_result =
        case resolve_comb_id(result_get(result, :options, :comb)) do
          {:ok, cid} -> Hive.Quests.create(%{goal: goal, comb_id: cid})
          {:error, :no_comb} -> Hive.Quests.create(%{goal: goal})
        end

      case quest_result do
        {:ok, quest} ->
          Format.success("Quest \"#{quest.name}\" created (#{quest.id})")
          Hive.CLI.PlanHandler.start_interactive_planning(quest)

        {:error, reason} ->
          Format.error("Failed to create quest: #{inspect(reason)}")
      end
    end
  end

  defp dispatch([:quest, :plan], result) do
    id = result_get(result, :args, :id)

    case Hive.Quests.get(id) do
      {:ok, quest} ->
        Hive.CLI.PlanHandler.start_interactive_planning(quest)

      {:error, :not_found} ->
        Format.error("Quest not found: #{id}")
    end
  end

  defp dispatch([:quest, :remove], result) do
    id = result_get(result, :args, :id)

    del_result =
      if Hive.Client.remote?(),
        do: Hive.Client.delete_quest(id),
        else: Hive.Quests.delete(id)

    case del_result do
      :ok ->
        Format.success("Quest #{id} removed.")

      {:error, :not_found} ->
        show_not_found_error(:quest, id)
    end
  end

  defp dispatch([:quest, :list], _result) do
    quests =
      if Hive.Client.remote?() do
        case Hive.Client.list_quests() do
          {:ok, q} -> q
          {:error, reason} -> Format.error("Remote error: #{inspect(reason)}"); []
        end
      else
        Hive.Quests.list()
      end

    case quests do
      [] ->
        Format.info("No quests. Create one with `hive quest \"<goal>\"`.")

      quests ->
        headers = ["ID", "Name", "Phase", "Status", "Comb"]

        rows =
          Enum.map(quests, fn q ->
            comb_name =
              if Hive.Client.remote?(), do: q[:comb_id] || "-", else: resolve_comb_name(q[:comb_id])
            phase = q[:current_phase] || "-"
            [q.id, q.name, phase, q.status, comb_name]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:quest, :show], result) do
    id = result_get(result, :args, :id)

    quest_result =
      if Hive.Client.remote?(),
        do: Hive.Client.get_quest(id),
        else: Hive.Quests.get(id)

    case quest_result do
      {:ok, quest} ->
        IO.puts("ID:     #{quest.id}")
        IO.puts("Name:   #{quest.name}")
        IO.puts("Status: #{quest.status}")

        if quest[:comb_id] do
          comb_name =
            if Hive.Client.remote?(), do: quest.comb_id, else: resolve_comb_name(quest.comb_id)
          IO.puts("Comb:   #{comb_name}")
        end

        unless Hive.Client.remote?() do
          if quest[:council_id] do
            council_label =
              case Hive.Council.get(quest.council_id) do
                {:ok, c} -> "#{c.domain} (#{c.id})"
                _ -> quest.council_id
              end

            IO.puts("Council: #{council_label}")
          end
        end

        if quest[:goal] do
          IO.puts("Goal:   #{quest.goal}")
        end

        IO.puts("")

        unless Hive.Client.remote?() do
          spec_phases = Hive.Specs.list_phases(id)

          if spec_phases != [] do
            IO.puts("Specs:  #{Enum.join(spec_phases, ", ")}")
            IO.puts("")
          end
        end

        jobs = quest[:jobs] || []

        case jobs do
          [] ->
            Format.info("No jobs in this quest.")

          jobs ->
            headers = ["Job ID", "Title", "Status", "Bee ID"]

            rows =
              Enum.map(jobs, fn j ->
                [j.id, j.title, j.status, j[:bee_id] || "-"]
              end)

            Format.table(headers, rows)
        end

      {:error, :not_found} ->
        show_not_found_error(:quest, id)
    end
  end

  defp dispatch([:jobs, :list], _result) do
    jobs =
      if Hive.Client.remote?() do
        case Hive.Client.list_jobs() do
          {:ok, j} -> j
          {:error, reason} -> Format.error("Remote error: #{inspect(reason)}"); []
        end
      else
        Hive.Jobs.list()
      end

    case jobs do
      [] ->
        Format.info("No jobs found.")

      jobs ->
        headers = ["ID", "Title", "Status", "Quest ID", "Bee ID"]

        rows =
          Enum.map(jobs, fn j ->
            [j.id, j.title, j.status, j[:quest_id], j[:bee_id] || "-"]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:jobs, :show], result) do
    id = result_get(result, :args, :id)

    job_result =
      if Hive.Client.remote?(),
        do: Hive.Client.get_job(id),
        else: Hive.Jobs.get(id)

    case job_result do
      {:ok, job} ->
        IO.puts("ID:          #{job.id}")
        IO.puts("Title:       #{job.title}")
        IO.puts("Status:      #{job.status}")
        IO.puts("Quest ID:    #{job[:quest_id]}")
        IO.puts("Comb ID:     #{job[:comb_id]}")
        IO.puts("Bee ID:      #{job[:bee_id] || "-"}")
        IO.puts("Created:     #{job[:inserted_at]}")
        IO.puts("")

        if job[:description] do
          IO.puts(job.description)
        end

      {:error, :not_found} ->
        show_not_found_error(:job, id)
        Format.info("Hint: use `hive jobs list` to see all jobs.")
    end
  end

  defp dispatch([:jobs, :create], result) do
    quest_id = result_get(result, :options, :quest)
    title = result_get(result, :options, :title)
    description = result_get(result, :options, :description)

    case resolve_comb_id(result_get(result, :options, :comb)) do
      {:ok, comb_id} ->
        attrs = %{
          quest_id: quest_id,
          title: title,
          comb_id: comb_id,
          description: description
        }

        case Hive.Jobs.create(attrs) do
          {:ok, job} ->
            Format.success("Job \"#{job.title}\" created (#{job.id})")

          {:error, reason} ->
            Format.error("Failed to create job: #{inspect(reason)}")
        end

      {:error, :no_comb} ->
        Format.error("No comb specified. Use --comb or set one with `hive comb use`.")
    end
  end

  defp dispatch([:jobs, :reset], result) do
    job_id = result_get(result, :args, :id)

    reset_result =
      if Hive.Client.remote?(),
        do: Hive.Client.reset_job(job_id),
        else: Hive.Jobs.reset(job_id)

    case reset_result do
      {:ok, job} ->
        Format.success("Job \"#{job.title}\" reset to #{job.status} (#{job.id})")

      {:error, :not_found} ->
        show_not_found_error(:job, job_id)

      {:error, :invalid_transition} ->
        Format.error("Job cannot be reset from its current status.")

      {:error, reason} ->
        Format.error("Failed to reset job: #{inspect(reason)}")
    end
  end

  defp dispatch([:costs, :summary], _result) do
    summary =
      if Hive.Client.remote?() do
        case Hive.Client.costs_summary() do
          {:ok, s} -> s
          {:error, reason} ->
            Format.error("Remote error: #{inspect(reason)}")
            System.halt(1)
        end
      else
        Hive.Costs.summary()
      end

    total_cost = summary[:total_cost] || 0.0
    IO.puts("Total cost:          $#{:erlang.float_to_binary(total_cost / 1, decimals: 4)}")
    IO.puts("Total input tokens:  #{summary[:total_input_tokens] || 0}")
    IO.puts("Total output tokens: #{summary[:total_output_tokens] || 0}")
    IO.puts("")

    by_model = summary[:by_model] || %{}
    if map_size(by_model) > 0 do
      IO.puts("By model:")
      headers = ["Model", "Cost", "Input Tokens", "Output Tokens"]

      rows =
        Enum.map(by_model, fn {model, data} ->
          cost = (data[:cost] || 0.0) / 1
          [
            model,
            "$#{:erlang.float_to_binary(cost, decimals: 4)}",
            "#{data[:input_tokens] || 0}",
            "#{data[:output_tokens] || 0}"
          ]
        end)

      Format.table(headers, rows)
      IO.puts("")
    end

    by_category = summary[:by_category] || %{}
    if map_size(by_category) > 0 do
      IO.puts("By category:")
      headers = ["Category", "Cost", "Input Tokens", "Output Tokens"]

      rows =
        Enum.map(by_category, fn {category, data} ->
          cost = (data[:cost] || 0.0) / 1
          [
            category,
            "$#{:erlang.float_to_binary(cost, decimals: 4)}",
            "#{data[:input_tokens] || 0}",
            "#{data[:output_tokens] || 0}"
          ]
        end)

      Format.table(headers, rows)
      IO.puts("")
    end

    by_bee = summary[:by_bee] || %{}
    if map_size(by_bee) > 0 do
      IO.puts("By bee:")
      headers = ["Bee ID", "Cost", "Input Tokens", "Output Tokens"]

      rows =
        Enum.map(by_bee, fn {bee_id, data} ->
          cost = (data[:cost] || 0.0) / 1
          [
            bee_id,
            "$#{:erlang.float_to_binary(cost, decimals: 4)}",
            "#{data[:input_tokens] || 0}",
            "#{data[:output_tokens] || 0}"
          ]
        end)

      Format.table(headers, rows)
    end
  end

  defp dispatch([:costs, :record], result) do
    if Hive.Client.remote?() do
      bee_id = result_get(result, :options, :bee)
      input = result_get(result, :options, :input)
      output = result_get(result, :options, :output)
      model = result_get(result, :options, :model)

      if is_nil(bee_id) or is_nil(input) or is_nil(output) do
        Format.error("--bee, --input, and --output are required (or use --queen)")
      else
        attrs = %{input_tokens: input, output_tokens: output, model: model}

        case Hive.Client.record_cost(bee_id, attrs) do
          {:ok, cost} ->
            Format.success("Cost recorded: $#{cost[:cost_usd]} (#{cost[:id]})")

          {:error, reason} ->
            Format.error("Failed to record cost: #{reason}")
        end
      end
    else
      queen? = result_get(result, :flags, :queen) || false

      if queen? do
        record_queen_costs()
      else
        bee_id = result_get(result, :options, :bee)
        input = result_get(result, :options, :input)
        output = result_get(result, :options, :output)
        model = result_get(result, :options, :model)

        if is_nil(bee_id) or is_nil(input) or is_nil(output) do
          Format.error("--bee, --input, and --output are required (or use --queen)")
        else
          attrs = %{input_tokens: input, output_tokens: output, model: model}
          {:ok, cost} = Hive.Costs.record(bee_id, attrs)

          Format.success(
            "Cost recorded: $#{:erlang.float_to_binary(cost.cost_usd, decimals: 6)} (#{cost.id})"
          )
        end
      end
    end
  end

  defp dispatch([:doctor], result) do
    fix? = result_get(result, :flags, :fix) || false
    results = Hive.Doctor.run_all(fix: fix?)

    Enum.each(results, fn check ->
      status_label = doctor_status_label(check.status)
      IO.puts("#{status_label} #{check.name}: #{check.message}")
    end)

    error_count = Enum.count(results, &(&1.status == :error))
    warn_count = Enum.count(results, &(&1.status == :warn))

    IO.puts("")

    cond do
      error_count > 0 ->
        Format.error("#{error_count} error(s), #{warn_count} warning(s)")

      warn_count > 0 ->
        Format.warn("#{warn_count} warning(s), no errors")

      true ->
        Format.success("All checks passed")
    end
  end

  defp dispatch([:quickref], _result) do
    IO.puts(Hive.CLI.Help.quick_reference())
  end

  defp dispatch([:handoff, :create], result) do
    bee_id = result_get(result, :options, :bee)

    case Hive.Handoff.create(bee_id) do
      {:ok, waggle} ->
        Format.success("Handoff created for #{bee_id} (waggle #{waggle.id})")

      {:error, :bee_not_found} ->
        show_not_found_error(:bee, bee_id)

      {:error, reason} ->
        Format.error("Handoff failed: #{inspect(reason)}")
    end
  end

  defp dispatch([:handoff, :show], result) do
    bee_id = result_get(result, :options, :bee)

    case Hive.Handoff.detect_handoff(bee_id) do
      {:ok, waggle} ->
        IO.puts("Handoff waggle: #{waggle.id}")
        IO.puts("Created: #{waggle.inserted_at}")
        IO.puts("")
        IO.puts(waggle.body || "(empty)")

      {:error, :no_handoff} ->
        Format.info("No handoff found for #{bee_id}")
    end
  end

  defp dispatch([:drone], result) do
    if Hive.Client.remote?() do
      Format.error("This command runs on the server. Run it there directly.")
      return_early()
    end

    no_fix = result_get(result, :flags, :no_fix) || false
    verify = result_get(result, :flags, :verify) || false

    case Hive.Drone.start_link(auto_fix: !no_fix, verify: verify) do
      {:ok, _pid} ->
        msg = if verify, do: "Drone started with verification enabled", else: "Drone started"
        Format.success("#{msg}. Running health patrols...")
        Process.sleep(:infinity)

      {:error, {:already_started, _pid}} ->
        Format.warn("Drone is already running.")

      {:error, reason} ->
        Format.error("Failed to start Drone: #{inspect(reason)}")
    end
  end

  defp dispatch([:server], result) do
    port = result_get(result, :options, :port) || 4000

    {:ok, _} = Application.ensure_all_started(:hive)

    url = "http://localhost:#{port}"
    Format.success("Hive server v#{Hive.version()} running at #{url}")
    Format.info("API available at #{url}/api/v1/health")
    Format.info("Press Ctrl+C to stop.")
    Process.sleep(:infinity)
  end

  defp dispatch([:dashboard], _result) do
    if Hive.Client.remote?() do
      Format.error("This command runs on the server. Run it there directly.")
      return_early()
    end

    do_start_dashboard()
  end

  # -- Phase 1: Job dependencies -----------------------------------------------

  defp dispatch([:jobs, :deps, :add], result) do
    job_id = result_get(result, :options, :job)
    depends_on = result_get(result, :options, :depends_on)

    case Hive.Jobs.add_dependency(job_id, depends_on) do
      {:ok, dep} ->
        Format.success("Dependency added (#{dep.id}): #{job_id} depends on #{depends_on}")

      {:error, :self_dependency} ->
        Format.error("A job cannot depend on itself.")

      {:error, :cycle_detected} ->
        Format.error("Adding this dependency would create a cycle.")

      {:error, reason} ->
        Format.error("Failed: #{inspect(reason)}")
    end
  end

  defp dispatch([:jobs, :deps, :remove], result) do
    job_id = result_get(result, :options, :job)
    depends_on = result_get(result, :options, :depends_on)

    case Hive.Jobs.remove_dependency(job_id, depends_on) do
      :ok -> Format.success("Dependency removed.")
      {:error, :not_found} -> Format.error("Dependency not found.")
    end
  end

  defp dispatch([:jobs, :deps, :list], result) do
    job_id = result_get(result, :options, :job)

    deps = Hive.Jobs.dependencies(job_id)
    dependents = Hive.Jobs.dependents(job_id)

    IO.puts("Dependencies of #{job_id}:")

    if deps == [] do
      Format.info("  (none)")
    else
      Enum.each(deps, fn j -> IO.puts("  #{j.id} - #{j.title} [#{j.status}]") end)
    end

    IO.puts("")
    IO.puts("Dependents on #{job_id}:")

    if dependents == [] do
      Format.info("  (none)")
    else
      Enum.each(dependents, fn j -> IO.puts("  #{j.id} - #{j.title} [#{j.status}]") end)
    end

    IO.puts("")
    IO.puts("Ready? #{Hive.Jobs.ready?(job_id)}")
  end

  # -- Phase 2: Budget ---------------------------------------------------------

  defp dispatch([:budget], result) do
    quest_id = result_get(result, :options, :quest)

    budget = Hive.Budget.budget_for(quest_id)
    spent = Hive.Budget.spent_for(quest_id)
    remaining = Hive.Budget.remaining(quest_id)

    IO.puts("Quest:     #{quest_id}")
    IO.puts("Budget:    $#{:erlang.float_to_binary(budget, decimals: 2)}")
    IO.puts("Spent:     $#{:erlang.float_to_binary(spent, decimals: 4)}")
    IO.puts("Remaining: $#{:erlang.float_to_binary(remaining, decimals: 4)}")

    if Hive.Budget.exceeded?(quest_id) do
      Format.error("BUDGET EXCEEDED")
    else
      pct = if budget > 0, do: Float.round(spent / budget * 100, 1), else: 0.0
      Format.info("#{pct}% of budget used")
    end
  end

  # -- Phase 3: Watch (progress) -----------------------------------------------

  defp dispatch([:watch], _result) do
    Hive.Progress.init()
    Format.info("Watching bee progress... (Ctrl+C to stop)")

    Stream.repeatedly(fn ->
      entries = Hive.Progress.all()

      IO.write(IO.ANSI.clear() <> IO.ANSI.home())
      IO.puts("Hive Progress (#{length(entries)} active bees)")
      IO.puts(String.duplicate("-", 60))

      if entries == [] do
        IO.puts("No active bees.")
      else
        Enum.each(entries, fn entry ->
          bee = entry[:bee_id] || "?"
          tool = entry[:tool] || "-"
          msg = entry[:message] || ""
          IO.puts("#{bee}  #{tool}  #{String.slice(msg, 0, 50)}")
        end)
      end

      Process.sleep(1000)
    end)
    |> Stream.run()
  end

  # -- Phase 4: Conflict check ------------------------------------------------

  defp dispatch([:conflict, :check], result) do
    bee_id = result_get(result, :options, :bee)

    if bee_id do
      case Hive.Bees.get(bee_id) do
        {:ok, bee} ->
          cell =
            Hive.Store.find_one(:cells, fn c -> c.bee_id == bee.id and c.status == "active" end)

          if cell do
            case Hive.Conflict.check(cell.id) do
              {:ok, :clean} ->
                Format.success("No conflicts detected.")

              {:error, :conflicts, files} ->
                Format.warn("Conflicts detected in #{length(files)} file(s):")
                Enum.each(files, fn f -> IO.puts("  #{f}") end)
            end
          else
            Format.info("No active cell for bee #{bee_id}")
          end

        {:error, :not_found} ->
          show_not_found_error(:bee, bee_id)
      end
    else
      results = Hive.Conflict.check_all_active()

      if results == [] do
        Format.info("No active cells to check.")
      else
        Enum.each(results, fn
          {:ok, cell_id, :clean} ->
            IO.puts("#{cell_id}: clean")

          {:error, cell_id, :conflicts, files} ->
            Format.warn("#{cell_id}: conflicts in #{Enum.join(files, ", ")}")
        end)
      end
    end
  end

  # -- Phase 5: Validate ------------------------------------------------------

  defp dispatch([:validate], result) do
    bee_id = result_get(result, :options, :bee)

    with {:ok, bee} <- Hive.Bees.get(bee_id),
         {:ok, job} <- Hive.Jobs.get(bee.job_id) do
      cell = Hive.Store.find_one(:cells, fn c -> c.bee_id == bee.id and c.status == "active" end)

      if cell do
        Format.info("Running validation for bee #{bee_id}...")

        case Hive.Validator.validate(bee_id, job, cell.id) do
          {:ok, :pass} ->
            Format.success("Validation passed.")

          {:ok, :skip} ->
            Format.info("Validation skipped (no diff or Claude unavailable).")

          {:error, reason, details} ->
            Format.error("Validation failed: #{inspect(reason)}")

            if is_map(details) do
              if details[:reasoning], do: IO.puts("Reasoning: #{details.reasoning}")
              if details[:issues], do: Enum.each(details.issues, fn i -> IO.puts("  - #{i}") end)
            end
        end
      else
        Format.info("No active cell for bee #{bee_id}")
      end
    else
      {:error, :not_found} -> Format.error("Bee or job not found: #{bee_id}")
      {:error, reason} -> Format.error("Failed: #{inspect(reason)}")
    end
  end

  # -- Phase 6: GitHub ---------------------------------------------------------

  defp dispatch([:github, :pr], result) do
    bee_id = result_get(result, :options, :bee)

    with {:ok, bee} <- Hive.Bees.get(bee_id),
         {:ok, job} <- Hive.Jobs.get(bee.job_id) do
      cell = Hive.Store.find_one(:cells, fn c -> c.bee_id == bee.id end)
      comb = cell && Hive.Store.get(:combs, cell.comb_id)

      cond do
        is_nil(cell) ->
          Format.error("No cell found for bee #{bee_id}")

        is_nil(comb) ->
          show_not_found_error(:comb, "unknown")

        is_nil(Map.get(comb, :github_owner)) || is_nil(Map.get(comb, :github_repo)) ->
          Format.error(
            "Comb #{comb.name} has no GitHub config. Use --github-owner and --github-repo when adding."
          )

        true ->
          case Hive.GitHub.create_pr(comb, cell, job) do
            {:ok, url} -> Format.success("PR created: #{url}")
            {:error, reason} -> Format.error("PR creation failed: #{inspect(reason)}")
          end
      end
    else
      {:error, :not_found} -> Format.error("Bee or job not found: #{bee_id}")
      {:error, reason} -> Format.error("Failed: #{inspect(reason)}")
    end
  end

  defp dispatch([:github, :issues], result) do
    case resolve_comb_id(result_get(result, :options, :comb)) do
      {:ok, comb_id} ->
        case Hive.Comb.get(comb_id) do
          {:ok, comb} ->
            case Hive.GitHub.list_issues(comb) do
              {:ok, issues} ->
                if issues == [] do
                  Format.info("No open issues.")
                else
                  headers = ["#", "Title", "State"]
                  rows = Enum.map(issues, fn i -> ["#{i["number"]}", i["title"], i["state"]] end)
                  Format.table(headers, rows)
                end

              {:error, reason} ->
                Format.error("Failed: #{inspect(reason)}")
            end

          {:error, _} ->
            show_not_found_error(:comb, comb_id)
        end

      {:error, :no_comb} ->
        Format.error("No comb specified. Use --comb or set one with `hive comb use`.")
    end
  end

  defp dispatch([:github, :sync], result) do
    case resolve_comb_id(result_get(result, :options, :comb)) do
      {:ok, comb_id} ->
        case Hive.Comb.get(comb_id) do
          {:ok, comb} ->
            case Hive.GitHub.list_issues(comb) do
              {:ok, issues} ->
                Format.info("Found #{length(issues)} open issues for #{comb.name}")
                Enum.each(issues, fn i -> IO.puts("  ##{i["number"]} #{i["title"]}") end)

              {:error, reason} ->
                Format.error("Sync failed: #{inspect(reason)}")
            end

          {:error, _} ->
            show_not_found_error(:comb, comb_id)
        end

      {:error, :no_comb} ->
        Format.error("No comb specified. Use --comb or set one with `hive comb use`.")
    end
  end

  defp dispatch([:quest, :spec, :write], result) do
    quest_id = result_get(result, :args, :quest_id)
    phase = result_get(result, :options, :phase)
    content = result_get(result, :options, :content)

    if Hive.Client.remote?() do
      content = content || IO.read(:stdio, :eof)

      case Hive.Client.quest_spec_write(quest_id, phase, content) do
        {:ok, _} -> Format.success("Spec written for #{phase}")
        {:error, reason} -> Format.error("Failed to write spec: #{format_error(reason)}")
      end
    else
      content =
        if content do
          content
        else
          IO.read(:stdio, :eof)
        end

      case Hive.Specs.write(quest_id, phase, content) do
        {:ok, path} ->
          Format.success("Spec written: #{path}")

        {:error, {:invalid_phase, p}} ->
          Format.error("Invalid phase: #{p}. Valid phases: #{Enum.join(Hive.Specs.phases(), ", ")}")

        {:error, reason} ->
          Format.error("Failed to write spec: #{format_error(reason)}")
      end
    end
  end

  defp dispatch([:quest, :spec, :show], result) do
    quest_id = result_get(result, :args, :quest_id)
    phase = result_get(result, :options, :phase)

    if Hive.Client.remote?() do
      case Hive.Client.quest_spec(quest_id, phase) do
        {:ok, data} -> IO.puts(data[:content] || inspect(data))
        {:error, :not_found} -> Format.error("No #{phase} spec found for quest #{quest_id}")
        {:error, reason} -> Format.error("Failed: #{format_error(reason)}")
      end
    else
      case Hive.Specs.read(quest_id, phase) do
        {:ok, content} ->
          IO.puts(content)

        {:error, :not_found} ->
          Format.error("No #{phase} spec found for quest #{quest_id}")

        {:error, {:invalid_phase, p}} ->
          Format.error("Invalid phase: #{p}. Valid phases: #{Enum.join(Hive.Specs.phases(), ", ")}")
      end
    end
  end

  defp dispatch([:quest, :status], result) do
    quest_id = result_get(result, :args, :quest_id)

    status_result =
      if Hive.Client.remote?(),
        do: Hive.Client.quest_status(quest_id),
        else: Hive.Queen.Orchestrator.get_quest_status(quest_id)

    case status_result do
      {:ok, status} ->
        quest = status[:quest] || %{}
        Format.info("Quest: #{quest[:name]} (#{quest[:id]})")
        Format.info("Current phase: #{status[:current_phase]}")
        Format.info("Completed phases: #{inspect(status[:completed_phases] || [])}")
        Format.info("Jobs created: #{status[:jobs_created]}")

        if status[:artifacts_summary] do
          Format.info("Artifacts: #{inspect(status[:artifacts_summary])}")
        end

        phase_history = status[:phase_history] || []
        if phase_history != [] do
          Format.info("Phase history:")
          Enum.each(phase_history, fn t ->
            IO.puts("  #{t[:from_phase]} → #{t[:to_phase]} (#{t[:reason]})")
          end)
        end

      {:error, reason} ->
        Format.error("Failed to get quest status: #{inspect(reason)}")
    end
  end

  # -- Council commands --------------------------------------------------------

  defp dispatch([:council, :create], result) do
    domain = result_get(result, :args, :domain)
    experts = result_get(result, :options, :experts)

    opts = if experts, do: [experts: experts], else: []

    Format.info("Researching experts for \"#{domain}\"...")

    case Hive.Council.create(domain, opts) do
      {:ok, council} ->
        Format.success("Council \"#{council.domain}\" created (#{council.id})")

        Enum.each(council.experts, fn e ->
          IO.puts("  #{e.key}: #{e.name} — #{e.focus}")
        end)

      {:error, {:already_exists, id}} ->
        Format.error("A council for this domain already exists (#{id})")

      {:error, reason} ->
        Format.error("Failed to create council: #{inspect(reason)}")
    end
  end

  defp dispatch([:council, :list], _result) do
    case Hive.Council.list() do
      [] ->
        Format.info("No councils. Use `hive council create <domain>` to create one.")

      councils ->
        headers = ["ID", "Name", "Domain", "Experts", "Status"]

        rows =
          Enum.map(councils, fn c ->
            [c.id, c.name, c.domain, "#{length(c.experts)}", c.status]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:council, :show], result) do
    id = result_get(result, :args, :id)

    case Hive.Council.get(id) do
      {:ok, council} ->
        IO.puts("ID:      #{council.id}")
        IO.puts("Name:    #{council.name}")
        IO.puts("Domain:  #{council.domain}")
        IO.puts("Status:  #{council.status}")
        IO.puts("Experts: #{length(council.experts)}")
        IO.puts("")

        Enum.each(council.experts, fn e ->
          IO.puts("  #{e.key}")
          IO.puts("    Name:          #{e.name}")
          IO.puts("    Focus:         #{e.focus}")
          IO.puts("    Philosophy:    #{e.philosophy}")
          IO.puts("    Contributions: #{Enum.join(e.contributions, ", ")}")
          IO.puts("")
        end)

      {:error, :not_found} ->
        Format.error("Council not found: #{id}")
        Format.info("Hint: use `hive council list` to see all councils.")
    end
  end

  defp dispatch([:council, :remove], result) do
    id = result_get(result, :args, :id)

    case Hive.Council.delete(id) do
      :ok ->
        Format.success("Council #{id} removed.")

      {:error, :not_found} ->
        Format.error("Council not found: #{id}")
        Format.info("Hint: use `hive council list` to see all councils.")
    end
  end

  defp dispatch([:council, :apply], result) do
    council_id = result_get(result, :args, :id)
    quest_id = result_get(result, :options, :quest)
    wave_size = result_get(result, :options, :wave_size)

    opts = if wave_size, do: [wave_size: wave_size], else: []

    case Hive.Council.apply_to_quest(council_id, quest_id, opts) do
      {:ok, %{wave_count: waves, jobs_created: jobs}} ->
        Format.success("Council applied: #{jobs} review jobs in #{waves} wave(s)")

      {:error, :not_found} ->
        Format.error("Council or quest not found.")

      {:error, {:not_ready, status}} ->
        Format.error("Council is not ready (status: #{status})")

      {:error, :no_implementation_jobs} ->
        Format.error("Quest has no implementation jobs to review.")

      {:error, reason} ->
        Format.error("Failed: #{inspect(reason)}")
    end
  end

  defp dispatch([:council, :preview], result) do
    domain = result_get(result, :args, :domain)
    experts = result_get(result, :options, :experts)

    opts = if experts, do: [experts: experts], else: []

    Format.info("Discovering experts for \"#{domain}\"...")

    case Hive.Council.preview(domain, opts) do
      {:ok, experts} ->
        IO.puts("")
        IO.puts("Identified #{length(experts)} expert(s):")
        IO.puts("")

        Enum.each(experts, fn e ->
          IO.puts("  #{e.key}: #{e.name}")
          IO.puts("    Focus:         #{e.focus}")
          IO.puts("    Philosophy:    #{e.philosophy}")
          IO.puts("    Contributions: #{Enum.join(e.contributions, ", ")}")
          IO.puts("")
        end)

      {:error, reason} ->
        Format.error("Preview failed: #{inspect(reason)}")
    end
  end

  defp dispatch(path, result) do
    case try_handlers(path, result) do
      :not_handled ->
        label = path |> Enum.map(&Atom.to_string/1) |> Enum.join(" ")
        Format.warn("\"#{label}\" is not yet implemented.")

      _ ->
        :ok
    end
  end

  # -- Dispatch helpers (not dispatch/2 clauses) -----------------------------

  @empty_costs %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0, model: nil}

  defp record_queen_costs do
    # Read costs from the latest Queen transcript if available
    case Hive.hive_dir() do
      {:ok, root} ->
        transcript_dir = Path.join([root, ".hive", "queen", ".claude", "projects"])

        costs = extract_costs_from_transcripts(transcript_dir)

        if costs.input_tokens > 0 or costs.output_tokens > 0 do
          attrs = %{
            input_tokens: costs.input_tokens,
            output_tokens: costs.output_tokens,
            cache_read_tokens: costs.cache_read_tokens,
            cache_write_tokens: costs.cache_write_tokens,
            model: costs.model
          }

          {:ok, cost} = Hive.Costs.record("queen", attrs)
          Format.success(
            "Queen cost recorded: $#{:erlang.float_to_binary(cost.cost_usd, decimals: 6)} (#{cost.id})"
          )
        else
          Format.info("No new queen costs to record.")
        end

      {:error, _} ->
        Format.error("Not in a hive workspace.")
    end
  end

  defp extract_costs_from_transcripts(dir) do
    if File.dir?(dir) do
      case Path.wildcard(Path.join([dir, "**", "*.jsonl"])) |> Enum.sort() |> List.last() do
        nil -> @empty_costs
        path ->
          path
          |> File.stream!()
          |> Enum.reduce(@empty_costs, fn line, acc ->
            case Jason.decode(line) do
              {:ok, %{"type" => "usage", "usage" => usage}} ->
                %{acc |
                  input_tokens: acc.input_tokens + (usage["input_tokens"] || 0),
                  output_tokens: acc.output_tokens + (usage["output_tokens"] || 0),
                  cache_read_tokens: acc.cache_read_tokens + (usage["cache_read_input_tokens"] || 0),
                  cache_write_tokens: acc.cache_write_tokens + (usage["cache_creation_input_tokens"] || 0)
                }

              {:ok, %{"type" => "result", "model" => model}} when is_binary(model) ->
                %{acc | model: model}

              _ -> acc
            end
          end)
      end
    else
      @empty_costs
    end
  rescue
    _ -> @empty_costs
  end

  # Guard helper: used after printing an error to skip the rest of a dispatch clause.
  # The throw is caught by dispatch/2's catch-all or simply ends the function.
  defp return_early, do: throw(:return_early)

  @doc false
  def format_error(:unknown_provider), do: "LLM provider not configured. Set GOOGLE_API_KEY or ANTHROPIC_API_KEY."
  def format_error(:not_found), do: "Not found."
  def format_error({:api_error, reason}), do: "API error: #{inspect(reason)}"
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason), do: inspect(reason)

  # Uses CLI.Errors for rich, contextual not-found messages with suggestions.
  defp show_not_found_error(:bee, id),
    do: IO.puts(Hive.CLI.Errors.format_error(:bee_not_found, %{bee_id: id}))

  defp show_not_found_error(:quest, id),
    do: IO.puts(Hive.CLI.Errors.format_error(:quest_not_found, %{quest_id: id}))

  defp show_not_found_error(:job, id),
    do: IO.puts(Hive.CLI.Errors.format_error(:job_not_found, %{job_id: id}))

  defp show_not_found_error(:comb, id),
    do: IO.puts(Hive.CLI.Errors.format_error(:comb_not_found, %{comb_id: id}))

  defp resolve_comb_id(explicit) when is_binary(explicit), do: {:ok, explicit}

  defp resolve_comb_id(nil) do
    case Hive.Comb.current() do
      {:ok, comb} -> {:ok, comb.id}
      {:error, :no_current_comb} -> {:error, :no_comb}
    end
  end

  defp resolve_comb_name(nil), do: "-"

  defp resolve_comb_name(comb_id) do
    case Hive.Comb.get(comb_id) do
      {:ok, comb} -> comb.name
      _ -> comb_id
    end
  end

  defp do_prime_queen do
    case Hive.hive_dir() do
      {:ok, hive_root} ->
        case Hive.Prime.prime(:queen, hive_root) do
          {:ok, markdown} -> IO.puts(markdown)
          {:error, reason} -> Format.error("Prime failed: #{inspect(reason)}")
        end

      {:error, :not_in_hive} ->
        IO.puts(Hive.CLI.Errors.format_error(:store_not_initialized))
    end
  end

  defp do_prime_bee(bee_id) do
    case Hive.Prime.prime(:bee, bee_id) do
      {:ok, markdown} -> IO.puts(markdown)
      {:error, :bee_not_found} -> show_not_found_error(:bee, bee_id)
      {:error, reason} -> Format.error("Prime failed: #{inspect(reason)}")
    end
  end

  defp do_start_dashboard do
    case Hive.Dashboard.Endpoint.start_link() do
      {:ok, _pid} ->
        port =
          Application.get_env(:hive, Hive.Dashboard.Endpoint)
          |> Keyword.get(:http, [])
          |> Keyword.get(:port, 4040)

        url = "http://localhost:#{port}"
        Format.success("Dashboard running at #{url}")
        Format.info("Press Ctrl+C to stop.")
        Process.sleep(:infinity)

      {:error, {:already_started, _pid}} ->
        Format.warn("Dashboard is already running.")

      {:error, reason} ->
        Format.error("Failed to start dashboard: #{inspect(reason)}")
    end
  end

  defp discover_nearby_repos do
    cwd = File.cwd!()

    current =
      if Hive.Git.repo?(cwd),
        do: [{". (current directory)", cwd}],
        else: []

    subdirs =
      case File.ls(cwd) do
        {:ok, entries} ->
          entries
          |> Enum.sort()
          |> Enum.filter(fn entry ->
            full = Path.join(cwd, entry)
            File.dir?(full) and not String.starts_with?(entry, ".") and Hive.Git.repo?(full)
          end)
          |> Enum.map(fn entry -> {entry, Path.join(cwd, entry)} end)

        {:error, _} ->
          []
      end

    current ++ subdirs
  end

  defp doctor_status_label(:ok), do: IO.ANSI.green() <> "OK" <> IO.ANSI.reset()
  defp doctor_status_label(:warn), do: IO.ANSI.yellow() <> "WARN" <> IO.ANSI.reset()
  defp doctor_status_label(:error), do: IO.ANSI.red() <> "FAIL" <> IO.ANSI.reset()

  # -- Optimus spec -----------------------------------------------------------

  defp build_optimus! do
    Optimus.new!(
      name: "hive",
      description: "The Hive - Multi-agent orchestration for Claude Code",
      version: Hive.version(),
      about: "Coordinate multiple Claude Code agents working on a shared codebase.",
      subcommands: [
        doctor: [
          name: "doctor",
          about: "Check system prerequisites and Hive health",
          flags: [
            fix: [
              long: "--fix",
              help: "Auto-fix fixable issues"
            ]
          ]
        ],
        quickref: [
          name: "quickref",
          about: "Show quick reference card with common commands"
        ],
        comb: [
          name: "comb",
          about: "Manage codebases (combs) tracked by this hive",
          subcommands: [
            add: [
              name: "add",
              about: "Register a codebase with the hive",
              args: [
                path: [
                  value_name: "PATH",
                  help: "Path to the git repository",
                  required: false,
                  parser: :string
                ]
              ],
              options: [
                name: [
                  short: "-n",
                  long: "--name",
                  help: "Human-friendly name for the comb",
                  parser: :string,
                  required: false
                ],
                merge_strategy: [
                  long: "--merge-strategy",
                  help: "Merge strategy: manual, auto_merge, or pr_branch (default: manual)",
                  parser: :string,
                  required: false
                ],
                validation_command: [
                  long: "--validation-command",
                  help: "Command to run for validation (e.g., 'mix test')",
                  parser: :string,
                  required: false
                ],
                github_owner: [
                  long: "--github-owner",
                  help: "GitHub repository owner",
                  parser: :string,
                  required: false
                ],
                github_repo: [
                  long: "--github-repo",
                  help: "GitHub repository name",
                  parser: :string,
                  required: false
                ]
              ],
              flags: [
                auto: [
                  short: "-a",
                  long: "--auto",
                  help: "Auto-detect project type and configure automatically"
                ]
              ]
            ],
            list: [
              name: "list",
              about: "List all registered combs"
            ],
            remove: [
              name: "remove",
              about: "Unregister a comb from the hive",
              args: [
                name: [
                  value_name: "NAME",
                  help: "Name of the comb to remove",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            use: [
              name: "use",
              about: "Set the current working comb",
              args: [
                name: [
                  value_name: "NAME",
                  help: "Name or ID of the comb to set as current",
                  required: false,
                  parser: :string
                ]
              ]
            ],
            rename: [
              name: "rename",
              about: "Rename a comb and update all tracking references",
              args: [
                name: [
                  value_name: "NAME",
                  help: "Current name or ID of the comb",
                  required: true,
                  parser: :string
                ],
                new_name: [
                  value_name: "NEW_NAME",
                  help: "New name for the comb",
                  required: true,
                  parser: :string
                ]
              ]
            ]
          ]
        ],
        queen: [
          name: "queen",
          about: "Start the queen orchestrator for a quest"
        ],
        bee: [
          name: "bee",
          about: "Manage bee worker agents",
          subcommands: [
            list: [
              name: "list",
              about: "List all bees and their status"
            ],
            spawn: [
              name: "spawn",
              about: "Spawn a new bee to work on a job",
              options: [
                job: [
                  short: "-j",
                  long: "--job",
                  help: "Job ID to assign to the bee",
                  parser: :string,
                  required: true
                ],
                comb: [
                  short: "-c",
                  long: "--comb",
                  help: "Comb ID (repository) to work in (defaults to current comb)",
                  parser: :string,
                  required: false
                ],
                name: [
                  short: "-n",
                  long: "--name",
                  help: "Custom name for the bee",
                  parser: :string,
                  required: false
                ]
              ]
            ],
            stop: [
              name: "stop",
              about: "Stop a running bee",
              options: [
                id: [
                  long: "--id",
                  help: "Bee ID to stop",
                  parser: :string,
                  required: true
                ]
              ]
            ],
            complete: [
              name: "complete",
              about: "Mark a bee as completed (used by wrapper scripts)",
              args: [
                bee_id: [
                  value_name: "BEE_ID",
                  help: "Bee ID to mark as completed",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            fail: [
              name: "fail",
              about: "Mark a bee as failed (used by wrapper scripts)",
              args: [
                bee_id: [
                  value_name: "BEE_ID",
                  help: "Bee ID to mark as failed",
                  required: true,
                  parser: :string
                ]
              ],
              options: [
                reason: [
                  long: "--reason",
                  help: "Failure reason",
                  parser: :string,
                  required: false
                ]
              ]
            ],
            revive: [
              name: "revive",
              about:
                "Revive a dead bee — spawn a new bee into its existing worktree to finish the work",
              args: [
                bee_id: [
                  value_name: "BEE_ID",
                  help: "ID of the dead bee whose worktree to reuse",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            context: [
              name: "context",
              about: "Show context usage statistics for a bee",
              args: [
                bee_id: [
                  value_name: "BEE_ID",
                  help: "Bee ID to check context usage",
                  required: true,
                  parser: :string
                ]
              ]
            ]
          ]
        ],
        quest: [
          name: "quest",
          about: "Manage quests (high-level objectives)",
          subcommands: [
            new: [
              name: "new",
              about: "Create a new quest with interactive planning session",
              args: [
                goal: [
                  value_name: "GOAL",
                  help: "The goal for this quest (omit for discovery mode)",
                  required: false,
                  parser: :string
                ]
              ],
              options: [
                comb: [
                  short: "-c",
                  long: "--comb",
                  help: "Comb ID (defaults to current comb)",
                  parser: :string,
                  required: false
                ]
              ]
            ],
            list: [
              name: "list",
              about: "List all quests"
            ],
            show: [
              name: "show",
              about: "Show quest details",
              args: [
                id: [
                  value_name: "ID",
                  help: "Quest identifier",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            remove: [
              name: "remove",
              about: "Remove a quest",
              args: [
                id: [
                  value_name: "ID",
                  help: "Quest ID to remove",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            merge: [
              name: "merge",
              about: "Merge all completed bee branches into a quest branch",
              args: [
                id: [
                  value_name: "ID",
                  help: "Quest ID to merge",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            report: [
              name: "report",
              about: "Show performance report for a quest run",
              args: [
                id: [
                  value_name: "ID",
                  help: "Quest ID to report on",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            close: [
              name: "close",
              about: "Close a quest and remove associated cells/worktrees",
              args: [
                id: [
                  value_name: "ID",
                  help: "Quest ID to close",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            plan: [
              name: "plan",
              about: "Start or resume interactive planning for a quest",
              args: [
                id: [
                  value_name: "ID",
                  help: "Quest ID to plan",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            spec: [
              name: "spec",
              about: "Manage quest planning specs (requirements, design, tasks)",
              subcommands: [
                write: [
                  name: "write",
                  about: "Write a spec phase for a quest",
                  args: [
                    quest_id: [
                      value_name: "QUEST_ID",
                      help: "Quest identifier",
                      required: true,
                      parser: :string
                    ]
                  ],
                  options: [
                    phase: [
                      short: "-p",
                      long: "--phase",
                      help: "Spec phase: requirements, design, or tasks",
                      parser: :string,
                      required: true
                    ],
                    content: [
                      short: "-c",
                      long: "--content",
                      help: "Spec content (reads stdin if omitted)",
                      parser: :string,
                      required: false
                    ]
                  ]
                ],
                show: [
                  name: "show",
                  about: "Show a spec phase for a quest",
                  args: [
                    quest_id: [
                      value_name: "QUEST_ID",
                      help: "Quest identifier",
                      required: true,
                      parser: :string
                    ]
                  ],
                  options: [
                    phase: [
                      short: "-p",
                      long: "--phase",
                      help: "Spec phase: requirements, design, or tasks",
                      parser: :string,
                      required: true
                    ]
                  ]
                ]
              ]
            ],
            status: [
              name: "status",
              about: "Show quest phase status and progress",
              args: [
                quest_id: [
                  value_name: "QUEST_ID",
                  help: "Quest identifier",
                  required: true,
                  parser: :string
                ]
              ]
            ]
          ]
        ],
        jobs: [
          name: "jobs",
          about: "List and inspect jobs in the current quest",
          subcommands: [
            list: [
              name: "list",
              about: "List all jobs in a quest"
            ],
            show: [
              name: "show",
              about: "Show job details",
              args: [
                id: [
                  value_name: "ID",
                  help: "Job identifier",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            create: [
              name: "create",
              about: "Create a new job",
              options: [
                quest: [
                  short: "-q",
                  long: "--quest",
                  help: "Quest ID to attach the job to",
                  parser: :string,
                  required: true
                ],
                title: [
                  short: "-t",
                  long: "--title",
                  help: "Job title",
                  parser: :string,
                  required: true
                ],
                comb: [
                  short: "-c",
                  long: "--comb",
                  help: "Comb ID for the job (defaults to current comb)",
                  parser: :string,
                  required: false
                ],
                description: [
                  short: "-d",
                  long: "--description",
                  help: "Detailed job description",
                  parser: :string,
                  required: false
                ]
              ]
            ],
            reset: [
              name: "reset",
              about: "Reset a stuck job back to pending",
              args: [
                id: [
                  value_name: "ID",
                  help: "Job ID to reset",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            deps: [
              name: "deps",
              about: "Manage job dependencies",
              subcommands: [
                add: [
                  name: "add",
                  about: "Add a dependency between jobs",
                  options: [
                    job: [
                      short: "-j",
                      long: "--job",
                      help: "Job ID that has the dependency",
                      parser: :string,
                      required: true
                    ],
                    depends_on: [
                      long: "--depends-on",
                      help: "Job ID that must complete first",
                      parser: :string,
                      required: true
                    ]
                  ]
                ],
                remove: [
                  name: "remove",
                  about: "Remove a dependency between jobs",
                  options: [
                    job: [
                      short: "-j",
                      long: "--job",
                      help: "Job ID",
                      parser: :string,
                      required: true
                    ],
                    depends_on: [
                      long: "--depends-on",
                      help: "Dependency job ID to remove",
                      parser: :string,
                      required: true
                    ]
                  ]
                ],
                list: [
                  name: "list",
                  about: "List dependencies for a job",
                  options: [
                    job: [
                      short: "-j",
                      long: "--job",
                      help: "Job ID to list dependencies for",
                      parser: :string,
                      required: true
                    ]
                  ]
                ]
              ]
            ]
          ]
        ],
        waggle: [
          name: "waggle",
          about: "View inter-agent messages (waggles)",
          subcommands: [
            list: [
              name: "list",
              about: "List recent waggle messages",
              options: [
                to: [
                  short: "-t",
                  long: "--to",
                  help: "Filter by recipient",
                  parser: :string,
                  required: false
                ]
              ]
            ],
            show: [
              name: "show",
              about: "Show a specific waggle message",
              args: [
                id: [
                  value_name: "ID",
                  help: "Waggle message identifier",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            send: [
              name: "send",
              about: "Send a waggle message",
              options: [
                from: [
                  short: "-f",
                  long: "--from",
                  help: "Sender ID",
                  parser: :string,
                  required: true
                ],
                to: [
                  short: "-t",
                  long: "--to",
                  help: "Recipient ID",
                  parser: :string,
                  required: true
                ],
                subject: [
                  short: "-s",
                  long: "--subject",
                  help: "Message subject",
                  parser: :string,
                  required: true
                ],
                body: [
                  short: "-b",
                  long: "--body",
                  help: "Message body",
                  parser: :string,
                  required: true
                ]
              ]
            ]
          ]
        ],
        costs: [
          name: "costs",
          about: "View token usage and cost reports",
          subcommands: [
            summary: [
              name: "summary",
              about: "Show aggregate cost summary"
            ],
            record: [
              name: "record",
              about: "Manually record a cost entry",
              flags: [
                queen: [
                  long: "--queen",
                  help: "Record costs for the queen session (reads from latest transcript)"
                ]
              ],
              options: [
                bee: [
                  short: "-b",
                  long: "--bee",
                  help: "Bee ID to record costs for",
                  parser: :string,
                  required: false
                ],
                input: [
                  long: "--input",
                  help: "Input token count",
                  parser: :integer,
                  required: false
                ],
                output: [
                  long: "--output",
                  help: "Output token count",
                  parser: :integer,
                  required: false
                ],
                model: [
                  short: "-m",
                  long: "--model",
                  help: "Model name (default: claude-sonnet-4-20250514)",
                  parser: :string,
                  required: false
                ]
              ]
            ]
          ]
        ],
        cell: [
          name: "cell",
          about: "Manage git worktree cells",
          subcommands: [
            list: [
              name: "list",
              about: "List active cells (worktrees)"
            ],
            clean: [
              name: "clean",
              about: "Remove stale cells"
            ]
          ]
        ],
        drone: [
          name: "drone",
          about: "Start the health patrol drone",
          flags: [
            no_fix: [
              long: "--no-fix",
              help: "Disable auto-fixing of issues"
            ],
            verify: [
              long: "--verify",
              help: "Enable automatic job verification"
            ]
          ]
        ],
        onboard: [
          name: "onboard",
          about: "Auto-detect and onboard a project",
          args: [
            path: [
              parser: :string,
              required: true,
              help: "Path to project directory"
            ]
          ],
          options: [
            name: [
              short: "-n",
              long: "--name",
              help: "Comb name (defaults to directory name)",
              parser: :string,
              required: false
            ],
            validation_command: [
              short: "-v",
              long: "--validation-command",
              help: "Override detected validation command",
              parser: :string,
              required: false
            ]
          ],
          flags: [
            quick: [
              short: "-q",
              long: "--quick",
              help: "Quick onboard without research generation"
            ],
            preview: [
              short: "-p",
              long: "--preview",
              help: "Preview detection results without creating comb"
            ]
          ]
        ],
        verify: [
          name: "verify",
          about: "Verify completed job work",
          options: [
            job: [
              short: "-j",
              long: "--job",
              help: "Job ID to verify",
              parser: :string,
              required: false
            ],
            quest: [
              short: "-q",
              long: "--quest",
              help: "Verify all jobs in a quest",
              parser: :string,
              required: false
            ]
          ]
        ],
        accept: [
          name: "accept",
          about: "Test acceptance criteria for jobs or quests",
          options: [
            job: [
              short: "-j",
              long: "--job",
              help: "Job ID to test",
              parser: :string,
              required: false
            ],
            quest: [
              short: "-q",
              long: "--quest",
              help: "Quest ID to test",
              parser: :string,
              required: false
            ]
          ]
        ],
        scope: [
          name: "scope",
          about: "Check for scope creep and violations",
          options: [
            job: [
              short: "-j",
              long: "--job",
              help: "Job ID to check",
              parser: :string,
              required: false
            ],
            quest: [
              short: "-q",
              long: "--quest",
              help: "Quest ID to check",
              parser: :string,
              required: false
            ]
          ]
        ],
        quality: [
          name: "quality",
          about: "Quality analysis and reporting",
          args: [
            subcommand: [
              help: "Subcommand: check, report, baseline, thresholds, trends",
              parser: :string,
              required: true
            ]
          ],
          options: [
            job: [
              short: "-j",
              long: "--job",
              help: "Job ID for quality check or baseline source",
              parser: :string,
              required: false
            ],
            quest: [
              short: "-q",
              long: "--quest",
              help: "Quest ID for quality report",
              parser: :string,
              required: false
            ],
            comb: [
              short: "-c",
              long: "--comb",
              help: "Comb ID for baseline management",
              parser: :string,
              required: false
            ]
          ]
        ],
        intelligence: [
          name: "intelligence",
          about: "Adaptive intelligence and failure analysis",
          args: [
            subcommand: [
              help: "Subcommand: analyze, retry, insights, learn, best-practices, recommend",
              parser: :string,
              required: true
            ]
          ],
          options: [
            job: [
              short: "-j",
              long: "--job",
              help: "Job ID for analysis or retry",
              parser: :string,
              required: false
            ],
            comb: [
              short: "-c",
              long: "--comb",
              help: "Comb ID for insights or learning",
              parser: :string,
              required: false
            ]
          ]
        ],
        heal: [
          name: "heal",
          about: "Run self-healing checks and repairs"
        ],
        monitor: [
          name: "monitor",
          about: "Production monitoring and observability",
          args: [
            action: [
              help: "Action: start, status, metrics, health",
              parser: :string,
              required: true
            ]
          ],
          options: [
            interval: [
              short: "-i",
              long: "--interval",
              help: "Monitoring interval in seconds (default: 60)",
              parser: :integer,
              required: false
            ]
          ]
        ],
        optimize: [
          name: "optimize",
          about: "Optimize resources and predict issues",
          options: [
            comb: [
              short: "-c",
              long: "--comb",
              help: "Comb ID for issue prediction",
              parser: :string,
              required: false
            ]
          ]
        ],
        deadlock: [
          name: "deadlock",
          about: "Detect and resolve dependency deadlocks",
          options: [
            quest: [
              short: "-q",
              long: "--quest",
              help: "Quest ID to check for deadlocks",
              parser: :string,
              required: true
            ]
          ]
        ],
        dashboard: [
          name: "dashboard",
          about: "Open the live TUI dashboard"
        ],
        server: [
          name: "server",
          about: "Start the Hive web server for real-time quest monitoring",
          options: [
            port: [
              short: "-p",
              long: "--port",
              help: "Port to listen on (default: 4000)",
              parser: :integer,
              required: false
            ]
          ]
        ],
        handoff: [
          name: "handoff",
          about: "Manage context-preserving bee handoffs",
          subcommands: [
            create: [
              name: "create",
              about: "Create a handoff for a bee",
              options: [
                bee: [
                  short: "-b",
                  long: "--bee",
                  help: "Bee ID to create handoff for",
                  parser: :string,
                  required: true
                ]
              ]
            ],
            show: [
              name: "show",
              about: "Show handoff context for a bee",
              options: [
                bee: [
                  short: "-b",
                  long: "--bee",
                  help: "Bee ID to show handoff for",
                  parser: :string,
                  required: true
                ]
              ]
            ]
          ]
        ],
        prime: [
          name: "prime",
          about: "Output context prompt for a Queen or Bee session",
          flags: [
            queen: [
              long: "--queen",
              help: "Prime the Queen with instructions and hive state"
            ]
          ],
          options: [
            bee: [
              short: "-b",
              long: "--bee",
              help: "Bee ID to prime with job context",
              parser: :string,
              required: false
            ]
          ]
        ],
        budget: [
          name: "budget",
          about: "Show budget status for a quest",
          options: [
            quest: [
              short: "-q",
              long: "--quest",
              help: "Quest ID to check budget for",
              parser: :string,
              required: true
            ]
          ]
        ],
        watch: [
          name: "watch",
          about: "Watch real-time bee progress"
        ],
        conflict: [
          name: "conflict",
          about: "Check for merge conflicts",
          subcommands: [
            check: [
              name: "check",
              about: "Check for merge conflicts in active cells",
              options: [
                bee: [
                  short: "-b",
                  long: "--bee",
                  help: "Bee ID to check (optional, checks all if omitted)",
                  parser: :string,
                  required: false
                ]
              ]
            ]
          ]
        ],
        validate: [
          name: "validate",
          about: "Run validation on a bee's completed work",
          options: [
            bee: [
              short: "-b",
              long: "--bee",
              help: "Bee ID to validate",
              parser: :string,
              required: true
            ]
          ]
        ],
        github: [
          name: "github",
          about: "GitHub integration commands",
          subcommands: [
            pr: [
              name: "pr",
              about: "Create a GitHub PR for a bee's work",
              options: [
                bee: [
                  short: "-b",
                  long: "--bee",
                  help: "Bee ID to create PR for",
                  parser: :string,
                  required: true
                ]
              ]
            ],
            issues: [
              name: "issues",
              about: "List GitHub issues for a comb",
              options: [
                comb: [
                  short: "-c",
                  long: "--comb",
                  help: "Comb ID (defaults to current comb)",
                  parser: :string,
                  required: false
                ]
              ]
            ],
            sync: [
              name: "sync",
              about: "Sync GitHub issues for a comb",
              options: [
                comb: [
                  short: "-c",
                  long: "--comb",
                  help: "Comb ID to sync (defaults to current comb)",
                  parser: :string,
                  required: false
                ]
              ]
            ]
          ]
        ],
        version: [
          name: "version",
          about: "Print the Hive version"
        ],
        verify: [
          name: "verify",
          about: "Verify completed jobs",
          options: [
            job: [
              short: "-j",
              long: "--job",
              help: "Job ID to verify",
              parser: :string,
              required: false
            ],
            quest: [
              short: "-q",
              long: "--quest",
              help: "Quest ID to verify all jobs",
              parser: :string,
              required: false
            ]
          ]
        ],
        council: [
          name: "council",
          about: "Manage expert councils for code review waves",
          subcommands: [
            create: [
              name: "create",
              about: "Research experts and create a council for a domain",
              args: [
                domain: [
                  value_name: "DOMAIN",
                  help: "The domain to research experts for (e.g., \"Web UI Design\")",
                  required: true,
                  parser: :string
                ]
              ],
              options: [
                experts: [
                  short: "-n",
                  long: "--experts",
                  help: "Number of experts to discover (default: 5)",
                  parser: :integer,
                  required: false
                ]
              ]
            ],
            list: [
              name: "list",
              about: "List all councils"
            ],
            show: [
              name: "show",
              about: "Show council details with experts",
              args: [
                id: [
                  value_name: "ID",
                  help: "Council identifier",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            remove: [
              name: "remove",
              about: "Remove a council and its agent files",
              args: [
                id: [
                  value_name: "ID",
                  help: "Council ID to remove",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            apply: [
              name: "apply",
              about: "Apply a council to a quest as review waves",
              args: [
                id: [
                  value_name: "ID",
                  help: "Council ID to apply",
                  required: true,
                  parser: :string
                ]
              ],
              options: [
                quest: [
                  short: "-q",
                  long: "--quest",
                  help: "Quest ID to apply council to",
                  parser: :string,
                  required: true
                ],
                wave_size: [
                  short: "-w",
                  long: "--wave-size",
                  help: "Experts per wave (default: 2)",
                  parser: :integer,
                  required: false
                ]
              ]
            ],
            preview: [
              name: "preview",
              about: "Dry-run: show what experts would be identified for a domain",
              args: [
                domain: [
                  value_name: "DOMAIN",
                  help: "The domain to preview experts for",
                  required: true,
                  parser: :string
                ]
              ],
              options: [
                experts: [
                  short: "-n",
                  long: "--experts",
                  help: "Number of experts (default: 5)",
                  parser: :integer,
                  required: false
                ]
              ]
            ]
          ]
        ]
      ]
    )
  end
end
