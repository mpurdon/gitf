defmodule GiTF.CLI do
  @moduledoc "Escript entry point. Parses argv and dispatches to subcommand handlers."

  require Logger
  alias GiTF.CLI.Format

  # -- Escript entry point ----------------------------------------------------

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    if GiTF.Client.remote?() do
      :logger.set_primary_config(:level, :error)
    end

    case extract_cmd_flag(argv) do
      {:cmd, cmd_argv} ->
        # Non-interactive mode: `gitf -c <cmd>` or `gitf --cmd <cmd>`
        run_cli(cmd_argv)

      :tui ->
        # Interactive mode: launch TUI
        launch_tui()

      {:mcp_serve} ->
        run_mcp_server()

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
      ["mcp-serve" | _] -> {:mcp_serve}
      _ -> {:cli, argv}
    end
  end

  defp run_mcp_server do
    # App is already started by the escript boot. Just run the server.
    # Boot-time log noise on stdout is filtered by the bin/gitf-mcp wrapper.
    GiTF.MCPServer.run()
  end

  defp launch_tui do
    case ensure_store() do
      :ok ->
        :logger.remove_handler(:default)
        suppress_stderr()

        {:ok, _} = Application.ensure_all_started(:gitf)
        start_major()

        Process.flag(:trap_exit, true)
        try do
          Ratatouille.run(GiTF.TUI.App,
            quit_events: [{:key, Ratatouille.Constants.key(:ctrl_c)}]
          )
        rescue
          _e in MatchError ->
            Format.warn("TUI failed to initialize (this is normal when running as a global escript).")
            Format.info("Please use standard CLI commands instead (e.g. gitf --help).")
        end

        # Drain any trapped exit messages
        receive do
          {:EXIT, _pid, _reason} -> :ok
        after
          100 -> :ok
        end

      :skip ->
        IO.puts(GiTF.CLI.Errors.format_error(:store_not_initialized))
        System.halt(1)
    end
  end

  defp run_cli(argv) do
    argv = extract_mode_flag(argv)
    argv = expand_defaults(argv)
    optimus = build_optimus!()

    case Optimus.parse(optimus, argv) do
      {:ok, _result} ->
        Optimus.Help.help(optimus, [], 80) |> Enum.each(&IO.puts/1)

      {:ok, subcommand_path, result} ->
        unless GiTF.Client.remote?(), do: maybe_ensure_store(subcommand_path)

        if GiTF.Client.remote?() do
          case GiTF.Client.ping() do
            :ok -> :ok
            {:error, reason} ->
              Format.error("Cannot connect to GiTF server at #{GiTF.Client.server_url()}. Is it running?")
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
        IO.puts("gitf #{GiTF.version()}")

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

  defp safe_gets(prompt) do
    case IO.gets(prompt) do
      :eof -> ""
      line when is_binary(line) -> String.trim(line)
    end
  end

  # Extract --mode <mode> from anywhere in argv, set GITF_EXECUTION_MODE, and strip it.
  # This allows `gitf --mode bedrock mission new "..."` or `gitf mission new "..." --mode cli`.
  @valid_modes ~w(api cli ollama bedrock)
  defp extract_mode_flag(argv) do
    case find_mode_flag(argv, [], nil) do
      {cleaned, nil} -> cleaned
      {cleaned, mode} when mode in @valid_modes ->
        System.put_env("GITF_EXECUTION_MODE", mode)
        cleaned
      {cleaned, bad_mode} ->
        Format.warn("Unknown mode '#{bad_mode}', ignoring. Valid: #{Enum.join(@valid_modes, ", ")}")
        cleaned
    end
  end

  defp find_mode_flag([], acc, mode), do: {Enum.reverse(acc), mode}
  defp find_mode_flag(["--mode", value | rest], acc, _mode), do: find_mode_flag(rest, acc, value)

  defp find_mode_flag(["-m", value | rest], acc, prev_mode) do
    if String.starts_with?(value, "-") do
      find_mode_flag(rest, [value | ["-m" | acc]], prev_mode)
    else
      find_mode_flag(rest, acc, value)
    end
  end

  defp find_mode_flag([head | rest], acc, mode), do: find_mode_flag(rest, [head | acc], mode)

  @quest_subcommands ~w(new list show remove sync report close spec plan start status)

  defp expand_defaults(["mission" | rest]) when rest != [] do
    case rest do
      [sub | _] when sub in @quest_subcommands -> ["mission" | rest]
      # Don't expand flags like --help into "mission new --help"
      [<<"-", _::binary>> | _] -> ["mission" | rest]
      _ -> ["mission", "new" | rest]
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

  defp start_major do
    File.write("/tmp/gitf_tui_debug.log",
      "[#{DateTime.utc_now()}] start_major called, gitf_dir=#{inspect(GiTF.gitf_dir())}\n", [:append])

    case GiTF.gitf_dir() do
      {:ok, root} ->
        # Use GenServer.start (not start_link) so a Major crash doesn't kill the TUI.
        result = GenServer.start(GiTF.Major, %{gitf_root: root}, name: GiTF.Major)
        File.write("/tmp/gitf_tui_debug.log",
          "[#{DateTime.utc_now()}] Major start: #{inspect(result)}\n", [:append])

        case result do
          {:ok, _pid} ->
            GiTF.Major.start_session()

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
    case GiTF.gitf_dir() do
      {:ok, root} ->
        store_dir = Path.join([root, ".gitf", "store"])

        case GiTF.Archive.start_link(data_dir: store_dir) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> Format.error("Archive error: #{inspect(reason)}")
        end

      {:error, :not_in_gitf} ->
        prompt_init()
    end
  end

  defp prompt_init do
    IO.puts("gitf v#{GiTF.version()}")
    IO.puts("")

    answer =
      case IO.gets("No gitf workspace found. Initialize one here? [y/n] ") do
        :eof -> "y"
        line when is_binary(line) -> line |> String.trim() |> String.downcase()
      end

    if answer in ["y", "yes"] do
      case GiTF.Init.init(".", force: false) do
        {:ok, expanded} ->
          Format.success("GiTF initialized at #{expanded}")
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
    GiTF.CLI.MissionHandler,
    GiTF.CLI.GhostHandler
  ]

  defp handler_helpers do
    %{
      result_get: &result_get/3,
      resolve_sector_id: &resolve_sector_id/1,
      resolve_sector_name: &resolve_sector_name/1
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
    quick = result_get(result, :flags, :quick) || false
    preview = result_get(result, :options, :preview) || false
    validation_cmd = result_get(result, :options, :validation_command)

    opts = []
    opts = if name, do: Keyword.put(opts, :name, name), else: opts
    opts = if validation_cmd, do: Keyword.put(opts, :validation_command, validation_cmd), else: opts

    cond do
      preview ->
        case GiTF.Onboarding.preview(path) do
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
            Format.info("  Sync Strategy: #{info.suggestions.sync_strategy}")
            Format.info("\nFile Counts:")
            Enum.each(info.codebase_map.file_count, fn {ext, count} ->
              Format.info("  #{ext}: #{count} files")
            end)
          {:error, reason} ->
            Format.error("Preview failed: #{reason}")
        end

      quick ->
        GiTF.CLI.Progress.with_spinner("Onboarding project...", fn ->
          GiTF.Onboarding.quick_onboard(path, opts)
        end)
        |> case do
          {:ok, result} ->
            Format.success("✓ Quick onboarded: #{result.sector.name}")
            Format.info("  Language: #{result.project_info.language}")
            Format.info("  Path: #{result.sector.path}")
            GiTF.CLI.Help.show_tip(:comb_added)
          {:error, reason} ->
            Format.error("Onboarding failed: #{reason}")
        end

      true ->
        GiTF.CLI.Progress.with_spinner("Analyzing project...", fn ->
          GiTF.Onboarding.onboard(path, opts)
        end)
        |> case do
          {:ok, result} ->
            Format.success("✓ Onboarded: #{result.sector.name}")
            Format.info("  Language: #{result.project_info.language}")
            if result.project_info.framework, do: Format.info("  Framework: #{result.project_info.framework}")
            Format.info("  Build Tool: #{result.project_info.build_tool}")
            if result.project_info.validation_command, do: Format.info("  Validation: #{result.project_info.validation_command}")
            Format.info("  Path: #{result.sector.path}")
            GiTF.CLI.Help.show_tip(:comb_added)
          {:error, reason} ->
            Format.error("Onboarding failed: #{reason}")
        end
    end
  end

  defp dispatch([:verify], result) do
    op_id = result_get(result, :options, :op)
    mission_id = result_get(result, :options, :mission)

    cond do
      op_id ->
        case GiTF.Audit.verify_job(op_id) do
          {:ok, :pass, result} ->
            Format.success("Job #{op_id} verification passed")
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
            Format.error("Job #{op_id} verification failed")
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
            Format.error("Audit error: #{inspect(reason)}")
        end

      mission_id ->
        case GiTF.Missions.get(mission_id) do
          {:ok, _quest} ->
            ops = GiTF.Ops.list(mission_id: mission_id)
            results = Enum.map(ops, fn op ->
              if op.status == "done" do
                case GiTF.Audit.verify_job(op.id) do
                  {:ok, status, _} -> {op.id, status}
                  {:error, _} -> {op.id, :error}
                end
              else
                {op.id, :skipped}
              end
            end)
            
            passed = Enum.count(results, fn {_, status} -> status == :pass end)
            failed = Enum.count(results, fn {_, status} -> status == :fail end)
            
            Format.info("Quest #{mission_id} verification: #{passed} passed, #{failed} failed")

          {:error, :not_found} ->
            show_not_found_error(:mission, mission_id)
        end

      true ->
        Format.error("Usage: section verify --op <id> OR --mission <id>")
    end
  end

  defp dispatch([:quality], result) do
    subcommand = result_get(result, :args, :subcommand)
    
    case subcommand do
      "check" ->
        op_id = result_get(result, :options, :op)
        if op_id do
          reports = GiTF.Quality.get_reports(op_id)
          if Enum.empty?(reports) do
            Format.warn("No quality reports for op #{op_id}")
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
          Format.error("Usage: section quality check --op <id>")
        end
      
      "report" ->
        mission_id = result_get(result, :options, :mission)
        if mission_id do
          ops = GiTF.Ops.list(mission_id: mission_id)
          scores = Enum.map(ops, fn op ->
            score = GiTF.Quality.calculate_composite_score(op.id)
            {op.id, score}
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
            Format.info("Quest #{mission_id} average quality: #{Float.round(avg_score, 1)}/100")
          else
            Format.warn("No quality data for mission #{mission_id}")
          end
        else
          Format.error("Usage: section quality report --mission <id>")
        end
      
      "baseline" ->
        sector_id = result_get(result, :options, :sector)
        op_id = result_get(result, :options, :op)
        
        cond do
          sector_id && op_id ->
            # Set baseline from op's performance report
            reports = GiTF.Quality.get_reports(op_id)
            perf_report = Enum.find(reports, &(&1.analysis_type == "performance"))
            
            if perf_report do
              {:ok, _} = GiTF.Quality.set_performance_baseline(sector_id, perf_report.issues)
              Format.success("Performance baseline set for sector #{sector_id}")
            else
              Format.error("No performance report found for op #{op_id}")
            end
          
          sector_id ->
            # Show current baseline
            case GiTF.Quality.get_performance_baseline(sector_id) do
              nil ->
                Format.warn("No baseline set for sector #{sector_id}")
              
              baseline ->
                Format.info("Performance baseline for sector #{sector_id}:")
                Enum.each(baseline.metrics, fn metric ->
                  Format.info("  • #{metric.name}: #{metric.value} #{metric.unit}")
                end)
            end
          
          true ->
            Format.error("Usage: section quality baseline --sector <id> [--op <id>]")
        end
      
      "thresholds" ->
        sector_id = result_get(result, :options, :sector)
        
        if sector_id do
          thresholds = GiTF.Quality.get_thresholds(sector_id)
          Format.info("Quality thresholds for sector #{sector_id}:")
          Format.info("  • Composite: #{thresholds.composite}/100")
          Format.info("  • Static: #{thresholds.static}/100")
          Format.info("  • Security: #{thresholds.security}/100")
          Format.info("  • Performance: #{thresholds.performance}/100")
        else
          Format.error("Usage: section quality thresholds --sector <id>")
        end
      
      "trends" ->
        sector_id = result_get(result, :options, :sector)
        
        if sector_id do
          stats = GiTF.Quality.get_quality_stats(sector_id)
          
          if stats.total_jobs == 0 do
            Format.warn("No quality data for sector #{sector_id}")
          else
            Format.info("Quality statistics for sector #{sector_id}:")
            Format.info("  • Average: #{stats.average}/100")
            Format.info("  • Min: #{stats.min}/100")
            Format.info("  • Max: #{stats.max}/100")
            Format.info("  • Trend: #{stats.trend}")
            Format.info("  • Total ops: #{stats.total_jobs}")
            
            IO.puts("")
            Format.info("Recent scores:")
            trends = GiTF.Quality.get_quality_trends(sector_id, 5)
            Enum.each(trends, fn t ->
              Format.info("  • #{t.op_id}: #{t.score}/100")
            end)
          end
        else
          Format.error("Usage: section quality trends --sector <id>")
        end
      
      _ ->
        Format.error("Usage: section quality <check|report|baseline|thresholds|trends> [options]")
    end
  end

  defp dispatch([:intel], result) do
    subcommand = result_get(result, :args, :subcommand)
    
    case subcommand do
      "analyze" ->
        op_id = result_get(result, :options, :op)
        
        if op_id do
          case GiTF.Intel.analyze_and_suggest(op_id) do
            {:ok, result} ->
              Format.info("Failure Analysis for op #{op_id}:")
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
          Format.error("Usage: section intel analyze --op <id>")
        end
      
      "retry" ->
        op_id = result_get(result, :options, :op)
        
        if op_id do
          case GiTF.Intel.auto_retry(op_id) do
            {:ok, new_job} ->
              Format.success("Created retry op: #{new_job.id}")
              Format.info("  Strategy: #{new_job.retry_strategy}")
              if new_job.retry_metadata[:note] do
                Format.info("  Note: #{new_job.retry_metadata.note}")
              end
            
            {:error, reason} ->
              Format.error("Retry failed: #{inspect(reason)}")
          end
        else
          Format.error("Usage: section intel retry --op <id>")
        end
      
      "insights" ->
        sector_id = result_get(result, :options, :sector)
        
        if sector_id do
          insights = GiTF.Intel.get_insights(sector_id)
          
          Format.info("Intel Insights for sector #{sector_id}:")
          Format.info("  Total ops: #{insights.total_jobs}")
          Format.info("  Failed ops: #{insights.failed_jobs}")
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
          Format.error("Usage: section intel insights --sector <id>")
        end
      
      "learn" ->
        sector_id = result_get(result, :options, :sector)
        
        if sector_id do
          case GiTF.Intel.learn(sector_id) do
            {:ok, learning} ->
              Format.success("Learned from #{learning.total_failures} failures")
              Format.info("  Patterns identified: #{length(learning.patterns)}")
            
            {:error, reason} ->
              Format.error("Learning failed: #{inspect(reason)}")
          end
        else
          Format.error("Usage: section intel learn --sector <id>")
        end
      
      "best-practices" ->
        sector_id = result_get(result, :options, :sector)
        
        if sector_id do
          practices = GiTF.Intel.get_best_practices(sector_id)
          
          if Enum.empty?(practices.common_factors || []) do
            Format.warn("No success patterns found for sector #{sector_id}")
          else
            Format.info("Best Practices for sector #{sector_id}:")
            
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
              Enum.each(practices.high_quality_examples, fn op_id ->
                Format.info("  • #{op_id}")
              end)
            end
          end
        else
          Format.error("Usage: section intel best-practices --sector <id>")
        end
      
      "recommend" ->
        sector_id = result_get(result, :options, :sector)
        
        if sector_id do
          recommendation = GiTF.Intel.recommend_approach(sector_id)
          
          Format.info("Recommended Approach for sector #{sector_id}:")
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
          Format.error("Usage: section intel recommend --sector <id>")
        end
      
      _ ->
        Format.error("Usage: section intel <analyze|retry|insights|learn|best-practices|recommend> [options]")
    end
  end

  defp dispatch([:heal], _result) do
    if GiTF.Client.remote?() do
      Format.error("This command runs on the server. Run it there directly.")
      return_early()
    end

    # heal is a convenience alias: runs medic checks + self-healing
    Format.info("Running self-healing checks...")

    results = GiTF.Medic.run_all(fix: true)
    issues = Enum.filter(results, &(&1.status in [:warn, :error]))

    if issues == [] do
      Format.success("System healthy, no repairs needed")
    else
      Enum.each(results, fn r ->
        case r.status do
          :ok -> Format.success("  #{r.name}: ok")
          :warn -> Format.warn("  #{r.name}: #{r.message}")
          :error -> Format.error("  #{r.name}: #{r.message}")
        end
      end)
    end

    # Also run autonomy self-heal for higher-level recovery
    auto_results = GiTF.Autonomy.self_heal()
    unless Enum.empty?(auto_results) do
      Format.success("Auto-repairs:")
      Enum.each(auto_results, fn {action, count} ->
        Format.info("  #{action}: #{count}")
      end)
    end
  end

  defp dispatch([:optimize], result) do
    if GiTF.Client.remote?() do
      Format.error("This command runs on the server. Run it there directly.")
      return_early()
    end

    sector_id = result_get(result, :options, :sector)
    
    if sector_id do
      # Predict issues
      predictions = GiTF.Autonomy.predict_issues(sector_id)
      
      if Enum.empty?(predictions) do
        Format.success("No issues predicted for sector #{sector_id}")
      else
        Format.warn("Predicted Issues for sector #{sector_id}:")
        Enum.each(predictions, fn {type, message} ->
          Format.warn("  • #{type}: #{message}")
        end)
      end
    else
      # Optimize resources
      recommendations = GiTF.Autonomy.optimize_resources()
      
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
    if GiTF.Client.remote?() do
      Format.error("This command runs on the server. Run it there directly.")
      return_early()
    end

    mission_id = result_get(result, :options, :mission)
    
    if mission_id do
      case GiTF.Resilience.detect_deadlock(mission_id) do
        {:ok, :no_deadlock} ->
          Format.success("No deadlock detected in mission #{mission_id}")
        
        {:error, {:deadlock, cycles}} ->
          Format.error("Deadlock detected in mission #{mission_id}!")
          Format.warn("Circular dependencies found:")
          Enum.each(cycles, fn cycle ->
            Format.warn("  • #{Enum.join(cycle, " → ")}")
          end)
          
          IO.puts("")
          Format.info("Attempting to resolve...")
          
          {:ok, :deadlock_resolved} = GiTF.Resilience.resolve_deadlock(mission_id, cycles)
          Format.success("Deadlock resolved")
      end
    else
      Format.error("Usage: section deadlock --mission <id>")
    end
  end

  defp dispatch([:monitor], result) do
    if GiTF.Client.remote?() do
      Format.error("This command runs on the server. Run it there directly.")
      return_early()
    end

    action = result_get(result, :args, :action)
    
    case action do
      "start" ->
        interval = result_get(result, :options, :interval) || 60
        Format.info("Starting monitoring (interval: #{interval}s)...")
        GiTF.Observability.start_monitoring(interval)
        Format.success("Monitoring started")
      
      "status" ->
        status = GiTF.Observability.status()
        
        Format.info("System Status:")
        IO.puts("  Health: #{status.health.status}")
        IO.puts("  Quests: #{status.metrics.missions.active} active, #{status.metrics.missions.completed} completed")
        IO.puts("  Ghosts: #{status.metrics.ghosts.active} active")
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
        metrics = GiTF.Observability.Metrics.export_prometheus()
        IO.puts(metrics)
      
      "health" ->
        # Same as `gitf medic`
        results = GiTF.Medic.run_all(fix: false)
        Enum.each(results, fn r ->
          case r.status do
            :ok -> Format.success("  #{r.name}: ok")
            :warn -> Format.warn("  #{r.name}: #{r.message}")
            :error -> Format.error("  #{r.name}: #{r.message}")
          end
        end)

      _ ->
        Format.error("Usage: gitf monitor <start|status|metrics|health>")
    end
  end

  defp dispatch([:accept], result) do
    op_id = result_get(result, :options, :op)
    mission_id = result_get(result, :options, :mission)
    
    cond do
      op_id ->
        Format.info("Testing acceptance criteria for op #{op_id}...")
        result = GiTF.Acceptance.test_acceptance(op_id)
        
        IO.puts("\nAcceptance Test Results:")
        IO.puts("  Goal Met: #{if result.goal_met, do: "✓", else: "✗"}")
        IO.puts("  In Scope: #{if result.in_scope, do: "✓", else: "✗"}")
        IO.puts("  Minimal: #{if result.is_minimal, do: "✓", else: "✗"}")
        IO.puts("  Quality: #{if result.quality_passed, do: "✓", else: "✗"}")
        IO.puts("")
        
        if result.ready_to_merge do
          Format.success("✓ Ready to sync")
        else
          Format.warn("✗ Not ready to sync")
          IO.puts("\nBlockers:")
          Enum.each(result.blockers, fn blocker ->
            Format.warn("  • #{blocker}")
          end)
        end
      
      mission_id ->
        Format.info("Testing acceptance criteria for mission #{mission_id}...")
        result = GiTF.Acceptance.test_quest_acceptance(mission_id)
        
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
        Format.error("Usage: section accept --op <id> OR --mission <id>")
    end
  end

  defp dispatch([:scope], result) do
    op_id = result_get(result, :options, :op)
    mission_id = result_get(result, :options, :mission)
    
    cond do
      op_id ->
        result = GiTF.Barrier.check_scope(op_id)
        
        IO.puts("Scope Check for op #{op_id}:")
        IO.puts("  In Scope: #{if result.in_scope, do: "✓", else: "✗"}")
        
        if !Enum.empty?(result.warnings) do
          IO.puts("\nWarnings:")
          Enum.each(result.warnings, fn {type, msg} ->
            Format.warn("  • #{type}: #{msg}")
          end)
        end
        
        IO.puts("\nRecommendation: #{result.recommendation}")
      
      mission_id ->
        result = GiTF.Barrier.check_quest_scope(mission_id)
        
        IO.puts("Scope Check for mission #{mission_id}:")
        IO.puts("  Total Jobs: #{result.total_jobs}")
        IO.puts("  Status: #{result.overall_status}")
        
        if !Enum.empty?(result.scope_warnings) do
          IO.puts("\nWarnings:")
          Enum.each(result.scope_warnings, fn {type, msg} ->
            Format.warn("  • #{type}: #{msg}")
          end)
        end
      
      true ->
        Format.error("Usage: section scope --op <id> OR --mission <id>")
    end
  end

  defp dispatch([:sector, :add], result) do
    path = result_get(result, :args, :path)

    if GiTF.Client.remote?() do
      unless path do
        Format.error("Remote mode requires an explicit path. Usage: section sector add <path>")
        System.halt(1)
      end

      name = result_get(result, :options, :name)
      opts = if name, do: [name: name], else: []

      case GiTF.Client.add_sector(path, opts) do
        {:ok, sector} -> Format.success("Sector \"#{sector.name}\" registered (#{sector.id})")
        {:error, reason} -> Format.error("Failed to add sector: #{inspect(reason)}")
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
              answer = safe_gets("Select a repo [1-#{length(repos)}]: ")

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

        case GiTF.Onboarding.onboard(path, opts) do
          {:ok, result} ->
            Format.success("Sector \"#{result.sector.name}\" auto-configured (#{result.sector.id})")
            Format.info("  Language: #{result.project_info.language}")
            if result.project_info.framework, do: Format.info("  Framework: #{result.project_info.framework}")
            if result.project_info.validation_command, do: Format.info("  Validation: #{result.project_info.validation_command}")
          {:error, reason} ->
            Format.error("Auto-configuration failed: #{reason}")
        end
      else
        # Original manual configuration
        name = result_get(result, :options, :name)
        sync_strategy = result_get(result, :options, :sync_strategy)
        validation_command = result_get(result, :options, :validation_command)
        github_owner = result_get(result, :options, :github_owner)
        github_repo = result_get(result, :options, :github_repo)

        opts = []
        opts = if name, do: Keyword.put(opts, :name, name), else: opts
        opts = if sync_strategy, do: Keyword.put(opts, :sync_strategy, sync_strategy), else: opts

        opts =
          if validation_command,
            do: Keyword.put(opts, :validation_command, validation_command),
            else: opts

        opts = if github_owner, do: Keyword.put(opts, :github_owner, github_owner), else: opts
        opts = if github_repo, do: Keyword.put(opts, :github_repo, github_repo), else: opts

        case GiTF.Sector.add(path, opts) do
          {:ok, sector} ->
            Format.success("Sector \"#{sector.name}\" registered (#{sector.id})")

          {:error, :path_not_found} ->
            Format.error("Path does not exist: #{path}")

          {:error, reason} ->
            Format.error("Failed to add sector: #{inspect(reason)}")
        end
      end
    end
  end

  defp dispatch([:sector, :list], _result) do
    sectors =
      if GiTF.Client.remote?() do
        case GiTF.Client.list_sectors() do
          {:ok, c} -> c
          {:error, reason} -> Format.error("Remote error: #{inspect(reason)}"); []
        end
      else
        GiTF.Sector.list()
      end

    case sectors do
      [] ->
        Format.info("No sectors registered. Use `gitf sector add <path>` to register one.")

      sectors ->
        current_id =
          unless GiTF.Client.remote?() do
            case GiTF.Sector.current() do
              {:ok, c} -> c.id
              _ -> nil
            end
          end

        headers = ["", "ID", "Name", "Path"]

        rows =
          Enum.map(sectors, fn c ->
            marker = if current_id && c.id == current_id, do: "*", else: ""
            [marker, c.id, c.name, c[:path] || c[:repo_url] || "-"]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:sector, :remove], result) do
    name = result_get(result, :args, :name)

    remove_result =
      if GiTF.Client.remote?(),
        do: GiTF.Client.remove_sector(name),
        else: GiTF.Sector.remove(name)

    case remove_result do
      :ok ->
        Format.success("Sector \"#{name}\" removed.")

      {:ok, sector} ->
        Format.success("Sector \"#{sector.name}\" removed.")

      {:error, :not_found} ->
        show_not_found_error(:sector, name)
    end
  end

  defp dispatch([:sector, :use], result) do
    name = result_get(result, :args, :name)

    if GiTF.Client.remote?() do
      unless name do
        Format.error("Remote mode requires an explicit name/id. Usage: section sector use <name>")
        System.halt(1)
      end

      case GiTF.Client.use_sector(name) do
        {:ok, sector} -> Format.success("Current sector set to \"#{sector.name}\" (#{sector.id})")
        {:error, :not_found} -> show_not_found_error(:sector, name)
        {:error, reason} -> Format.error("Failed to set current sector: #{inspect(reason)}")
      end
    else
      if name do
        case GiTF.Sector.set_current(name) do
          {:ok, sector} ->
            Format.success("Current sector set to \"#{sector.name}\" (#{sector.id})")

          {:error, :not_found} ->
            show_not_found_error(:sector, name)

          {:error, reason} ->
            Format.error("Failed to set current sector: #{inspect(reason)}")
        end
      else
        case GiTF.Sector.list() do
          [] ->
            IO.puts(GiTF.CLI.Errors.format_error(:no_sectors))

          sectors ->
            IO.puts("Registered sectors:")

            sectors
            |> Enum.with_index(1)
            |> Enum.each(fn {c, idx} ->
              IO.puts("  #{idx}) #{c.name} (#{c.id})")
            end)

            IO.puts("")
            answer = safe_gets("Select a sector [1-#{length(sectors)}]: ")

            case Integer.parse(answer) do
              {n, ""} when n >= 1 and n <= length(sectors) ->
                sector = Enum.at(sectors, n - 1)

                case GiTF.Sector.set_current(sector.id) do
                  {:ok, c} ->
                    Format.success("Current sector set to \"#{c.name}\" (#{c.id})")

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

  defp dispatch([:sector, :rename], result) do
    name = result_get(result, :args, :name)
    new_name = result_get(result, :args, :new_name)

    case GiTF.Sector.rename(name, new_name) do
      {:ok, sector} ->
        Format.success("Sector renamed to \"#{sector.name}\" (#{sector.id})")

      {:error, :not_found} ->
        show_not_found_error(:sector, name)

      {:error, :name_already_taken} ->
        Format.error("A sector named \"#{new_name}\" already exists.")

      {:error, {:rename_failed, reason}} ->
        Format.error("Failed to rename directory: #{inspect(reason)}")

      {:error, reason} ->
        Format.error("Failed to rename sector: #{inspect(reason)}")
    end
  end

  defp dispatch([:link_msg, :list], result) do
    to = result_get(result, :options, :to)
    opts = if to, do: [to: to], else: []

    case GiTF.Link.list(opts) do
      [] ->
        Format.info("No link_msg messages found.")

      links ->
        headers = ["ID", "From", "To", "Subject", "Read"]

        rows =
          Enum.map(links, fn w ->
            [w.id, w.from, w.to, w.subject || "-", if(w.read, do: "yes", else: "no")]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:link_msg, :show], result) do
    id = result_get(result, :args, :id)

    case GiTF.Archive.get(:links, id) do
      nil ->
        Format.error("Link not found: #{id}")
        Format.info("Hint: use `gitf link list` to see all messages.")

      link_msg ->
        IO.puts("ID:      #{link_msg.id}")
        IO.puts("From:    #{link_msg.from}")
        IO.puts("To:      #{link_msg.to}")
        IO.puts("Subject: #{link_msg.subject || "-"}")
        IO.puts("Read:    #{link_msg.read}")
        IO.puts("Sent:    #{link_msg.inserted_at}")
        IO.puts("")

        if link_msg.body do
          IO.puts(link_msg.body)
        end
    end
  end

  defp dispatch([:link_msg, :send], result) do
    from = result_get(result, :options, :from)
    to = result_get(result, :options, :to)
    subject = result_get(result, :options, :subject)
    body = result_get(result, :options, :body)

    {:ok, link_msg} = GiTF.Link.send(from, to, subject, body)
    Format.success("Link sent (#{link_msg.id})")
  end

  defp dispatch([:shell, :list], _result) do
    case GiTF.Shell.list(status: "active") do
      [] ->
        Format.info("No active shells. Use `gitf shell list` after spawning a ghost.")

      shells ->
        headers = ["ID", "Ghost ID", "Sector ID", "Branch", "Path"]

        rows =
          Enum.map(shells, fn c ->
            [c.id, c.ghost_id, c.sector_id, c.branch, c.worktree_path]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:shell, :clean], _result) do
    case GiTF.Shell.cleanup_orphans() do
      {:ok, 0} ->
        Format.info("No orphaned shells found.")

      {:ok, count} ->
        Format.success("Marked #{count} orphaned shell(s) as removed.")
    end
  end

  defp dispatch([:brief], result) do
    ghost_id = result_get(result, :options, :ghost)
    queen? = result_get(result, :flags, :major) || false

    if GiTF.Client.remote?() do
      # In remote mode, brief is a no-op — the ghost works without local context injection
      :ok
    else
      cond do
        queen? ->
          do_prime_major()

        is_binary(ghost_id) ->
          do_prime_bee(ghost_id)

        true ->
          Format.error("Specify --queen or --ghost <id>")
      end
    end
  end

  defp dispatch([:major], _result) do
    case GiTF.gitf_dir() do
      {:ok, gitf_root} ->
        case GiTF.Major.start_link(gitf_root: gitf_root) do
          {:ok, _pid} ->
            GiTF.Major.start_session()

            # Print messages BEFORE launching Claude, not after.
            # Once Claude starts, it takes full control of the terminal --
            # any BEAM writes to stdout would corrupt Claude's TUI rendering.
            Format.success("Major is active at #{gitf_root}")

            case GiTF.Major.launch() do
              :ok ->
                :ok

              {:error, reason} ->
                Format.warn("Could not launch Claude: #{inspect(reason)}")
                Format.info("Major running without Claude. Listening for links.")
            end

            GiTF.Major.await_session_end()

          {:error, {:already_started, _pid}} ->
            Format.warn("Major is already running.")

          {:error, reason} ->
            Format.error("Failed to start Major: #{inspect(reason)}")
        end

      {:error, :not_in_gitf} ->
        IO.puts(GiTF.CLI.Errors.format_error(:store_not_initialized))
        Format.info("Hint: use `gitf init` or `gitf init --quick` to create a workspace.")
    end
  end

  defp dispatch([:ghost, :list], _result) do
    ghosts =
      if GiTF.Client.remote?() do
        case GiTF.Client.list_bees() do
          {:ok, b} -> b
          {:error, reason} -> Format.error("Remote error: #{inspect(reason)}"); []
        end
      else
        GiTF.Ghosts.list()
      end

    case ghosts do
      [] ->
        Format.info("No ghosts. Ghosts are spawned when the Major assigns ops.")

      ghosts ->
        headers = ["ID", "Name", "Status", "Job ID", "Context %"]

        rows =
          Enum.map(ghosts, fn b ->
            context_pct =
              case b[:context_percentage] do
                nil -> "-"
                pct when is_number(pct) -> "#{Float.round(pct * 100, 1)}%"
                _ -> "-"
              end

            [b.id, b.name, b.status, b[:op_id] || "-", context_pct]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:ghost, :spawn], result) do
    op_id = result_get(result, :options, :op)
    name = result_get(result, :options, :name)

    case resolve_sector_id(result_get(result, :options, :sector)) do
      {:ok, sector_id} ->
        with {:ok, gitf_root} <- GiTF.gitf_dir(),
             {:ok, sector} <- GiTF.Sector.get(sector_id) do
          opts = if name, do: [name: name], else: []

          case GiTF.Ghosts.spawn_detached(op_id, sector.id, gitf_root, opts) do
            {:ok, ghost} ->
              Format.success("Ghost \"#{ghost.name}\" spawned (#{ghost.id})")

            {:error, reason} ->
              Format.error("Failed to spawn ghost: #{inspect(reason)}")
          end
        else
          {:error, :not_in_gitf} ->
            IO.puts(GiTF.CLI.Errors.format_error(:store_not_initialized))

          {:error, :not_found} ->
            show_not_found_error(:sector, sector_id)

          {:error, reason} ->
            Format.error("Failed: #{inspect(reason)}")
        end

      {:error, :no_sector} ->
        Format.error("No sector specified. Use --sector or set one with `gitf sector use`.")
    end
  end

  defp dispatch([:ghost, :stop], result) do
    ghost_id = result_get(result, :options, :id)

    stop_result =
      if GiTF.Client.remote?(),
        do: GiTF.Client.stop_ghost(ghost_id),
        else: GiTF.Ghosts.stop(ghost_id)

    case stop_result do
      :ok ->
        Format.success("Ghost #{ghost_id} stopped.")

      {:error, :not_found} ->
        show_not_found_error(:ghost, ghost_id)
    end
  end

  defp dispatch([:ghost, :complete], result) do
    ghost_id = result_get(result, :args, :ghost_id)

    if GiTF.Client.remote?() do
      case GiTF.Client.complete_bee(ghost_id) do
        :ok -> Format.success("Ghost #{ghost_id} marked as completed.")
        {:error, reason} -> Format.error("Failed: #{inspect(reason)}")
      end
    else
      case GiTF.Ghosts.get(ghost_id) do
        {:ok, ghost} ->
          GiTF.Archive.put(:ghosts, %{ghost | status: "stopped"})

          if ghost.op_id do
            GiTF.Ops.complete(ghost.op_id)
            GiTF.Ops.unblock_dependents(ghost.op_id)

            GiTF.Telemetry.emit([:gitf, :ghost, :completed], %{}, %{
              ghost_id: ghost_id,
              op_id: ghost.op_id
            })

            # Find the ghost's shell and trigger Tachikoma verification pipeline
            # (same path as Worker.mark_success for standard ops)
            shell = GiTF.Archive.find_one(:shells, fn c ->
              c.ghost_id == ghost_id and c.status == "active"
            end)

            op = case GiTF.Ops.get(ghost.op_id) do
              {:ok, j} -> j
              _ -> nil
            end

            is_phase = op && Map.get(op, :phase_job, false)
            is_scout = op && Map.get(op, :recon, false)
            skip_verify = op && Map.get(op, :skip_verification, false)

            cond do
              is_scout ->
                GiTF.Link.send(ghost_id, "major", "scout_complete",
                  Jason.encode!(%{scout_op_id: ghost.op_id, parent_op_id: Map.get(op, :scout_for)}))

              is_phase ->
                GiTF.Link.send(ghost_id, "major", "job_complete",
                  "Job #{ghost.op_id} completed successfully (phase: #{op.phase})")

              skip_verify ->
                GiTF.Link.send(ghost_id, "major", "job_complete",
                  "Job #{ghost.op_id} completed (skip_verification)")

              shell != nil ->
                # Standard ops: route through Tachikoma for verification → merge pipeline
                Phoenix.PubSub.broadcast(
                  GiTF.PubSub,
                  "tachikoma:review",
                  {:review_job, ghost.op_id, ghost_id, shell.id}
                )

              true ->
                # No shell found — fall back to direct link to Major
                GiTF.Link.send(ghost_id, "major", "job_complete",
                  "Job #{ghost.op_id} completed successfully")
            end
          end

          Format.success("Ghost #{ghost_id} marked as completed.")

        {:error, _} ->
          show_not_found_error(:ghost, ghost_id)
      end
    end
  end

  defp dispatch([:ghost, :fail], result) do
    ghost_id = result_get(result, :args, :ghost_id)
    reason = result_get(result, :options, :reason) || "unknown"

    if GiTF.Client.remote?() do
      case GiTF.Client.fail_bee(ghost_id, reason) do
        :ok -> Format.success("Ghost #{ghost_id} marked as failed: #{reason}")
        {:error, err} -> Format.error("Failed: #{inspect(err)}")
      end
    else
      case GiTF.Ghosts.get(ghost_id) do
        {:ok, ghost} ->
          GiTF.Archive.put(:ghosts, %{ghost | status: "crashed"})

          if ghost.op_id do
            GiTF.Ops.fail(ghost.op_id)

            GiTF.Telemetry.emit([:gitf, :ghost, :failed], %{}, %{
              ghost_id: ghost_id,
              op_id: ghost.op_id,
              error: reason
            })

            GiTF.Link.send(ghost_id, "major", "job_failed", "Job #{ghost.op_id} failed: #{reason}")
          end

          Format.success("Ghost #{ghost_id} marked as failed: #{reason}")

        {:error, _} ->
          show_not_found_error(:ghost, ghost_id)
      end
    end
  end

  defp dispatch([:ghost, :revive], result) do
    dead_ghost_id = result_get(result, :args, :ghost_id)

    with {:ok, gitf_root} <- GiTF.gitf_dir() do
      case GiTF.Ghosts.revive(dead_ghost_id, gitf_root) do
        {:ok, ghost} ->
          Format.success(
            "Revived into ghost \"#{ghost.name}\" (#{ghost.id}) using #{dead_ghost_id}'s worktree"
          )

        {:error, reason} ->
          Format.error("Failed to revive: #{inspect(reason)}")
      end
    else
      {:error, :not_in_gitf} ->
        IO.puts(GiTF.CLI.Errors.format_error(:store_not_initialized))
    end
  end

  defp dispatch([:ghost, :context], result) do
    ghost_id = result_get(result, :args, :ghost_id)

    case GiTF.Runtime.ContextMonitor.get_usage_stats(ghost_id) do
      {:ok, stats} ->
        IO.puts("Ghost: #{ghost_id}")
        IO.puts("Context Usage:")
        IO.puts("  Tokens used:  #{stats.tokens_used}")
        IO.puts("  Tokens limit: #{stats.tokens_limit || "unknown"}")
        IO.puts("  Percentage:   #{Float.round(stats.percentage * 100, 2)}%")
        IO.puts("  Status:       #{stats.status}")
        IO.puts("  Needs transfer: #{stats.needs_handoff}")

        if stats.needs_handoff do
          Format.error("\n⚠️  This ghost needs a transfer - context usage is critical!")
        end

      {:error, :not_found} ->
        show_not_found_error(:ghost, ghost_id)
    end
  end

  defp dispatch([:mission, :report], result) do
    id = result_get(result, :args, :id)

    if GiTF.Client.remote?() do
      case GiTF.Client.quest_report(id) do
        {:ok, report} -> IO.puts(report[:text] || inspect(report))
        {:error, reason} -> Format.error("Report failed: #{format_error(reason)}")
      end
    else
      case GiTF.Report.generate(id) do
        {:ok, report} ->
          IO.puts(GiTF.Report.format(report))

        {:error, :not_found} ->
          show_not_found_error(:mission, id)

        {:error, reason} ->
          Format.error("Report failed: #{format_error(reason)}")
      end
    end
  end

  defp dispatch([:mission, :sync], result) do
    id = result_get(result, :args, :id)

    if GiTF.Client.remote?() do
      case GiTF.Client.quest_merge(id) do
        {:ok, data} -> Format.success("All ghost branches merged into #{data[:branch] || "mission branch"}")
        {:error, reason} -> Format.error("Quest sync failed: #{format_error(reason)}")
      end
    else
      case GiTF.Sync.merge_quest(id) do
        {:ok, branch} ->
          Format.success("All ghost branches merged into #{branch}")

        {:error, :not_found} ->
          show_not_found_error(:mission, id)

        {:error, :no_cells} ->
          Format.error("No active shells to sync for this mission.")

        {:error, {:merge_conflicts, branch, failed}} ->
          Format.warn("Syncd into #{branch} with conflicts in: #{Enum.join(failed, ", ")}")

        {:error, reason} ->
          Format.error("Quest sync failed: #{format_error(reason)}")
      end
    end
  end

  defp dispatch([:mission, :close], result) do
    id = result_get(result, :args, :id)

    close_result =
      if GiTF.Client.remote?(),
        do: GiTF.Client.close_quest(id),
        else: GiTF.Missions.close(id)

    case close_result do
      {:ok, mission} ->
        Format.success("Quest \"#{mission.name}\" closed. Associated shells removed.")

      {:error, :not_found} ->
        show_not_found_error(:mission, id)
    end
  end

  defp dispatch([:run], result) do
    goal = result_get(result, :args, :goal)

    sector_id =
      case resolve_sector_id(result_get(result, :options, :sector)) do
        {:ok, cid} -> cid
        {:error, :no_sector} ->
          # Auto-pick the first sector if only one exists
          case GiTF.Sector.list() do
            [sector] -> sector.id
            [] ->
              Format.error("No sectors registered. Run `gitf init` first.")
              System.halt(1)
            _multiple ->
              Format.error("Multiple sectors found. Specify one with --sector.")
              System.halt(1)
          end
      end

    Format.info("Creating task: #{goal}")

    case GiTF.Missions.create(%{goal: goal, sector_id: sector_id}) do
      {:ok, mission} ->
        Format.success("Mission #{mission.id} created")

        case GiTF.Major.Orchestrator.start_quest(mission.id, force_fast_path: true) do
          {:ok, phase} ->
            Format.success("Running (phase: #{phase})")

            if GiTF.Runtime.ModelResolver.api_mode?() do
              # API mode: ghost runs in-process via Worker — keep alive until done
              Format.info("Ghost working via API (waiting for completion)...")
              wait_for_mission(mission.id)
            else
              Format.info("Ghost is working. Track progress with: gitf mission show #{mission.id}")
            end

          {:error, reason} ->
            Format.error("Failed to start: #{inspect(reason)}")
        end

      {:error, reason} ->
        Format.error("Failed to create mission: #{inspect(reason)}")
    end
  end

  defp wait_for_mission(mission_id) do
    Process.sleep(2_000)

    case GiTF.Missions.get(mission_id) do
      {:ok, mission} ->
        ops = GiTF.Ops.list(mission_id: mission_id)
        all_terminal = Enum.all?(ops, &(&1.status in ["done", "failed", "rejected"]))

        if all_terminal do
          done = Enum.count(ops, &(&1.status == "done"))
          failed = Enum.count(ops, &(&1.status == "failed"))

          if failed == 0 do
            Format.success("Mission completed. #{done} op(s) done.")
          else
            Format.warn("Mission finished. #{done} done, #{failed} failed.")
          end
        else
          running = Enum.count(ops, &(&1.status in ["running", "assigned"]))
          Format.info("  #{running} op(s) still running...")
          wait_for_mission(mission_id)
        end

      _ ->
        Format.error("Mission not found")
    end
  end

  defp dispatch([:mission, :new], result) do
    goal = result_get(result, :args, :goal)

    if GiTF.Client.remote?() do
      sector_opt = result_get(result, :options, :sector)
      attrs = if sector_opt, do: %{goal: goal, sector_id: sector_opt}, else: %{goal: goal}

      case GiTF.Client.create_quest(attrs) do
        {:ok, mission} ->
          Format.success("Quest \"#{mission.name}\" created (#{mission.id})")
          Format.info("Starting mission execution on remote server...")

          case GiTF.Client.start_quest(mission.id) do
            {:ok, data} ->
              phase = if is_map(data), do: data[:phase], else: data
              Format.success("Quest #{mission.id} is now in #{phase} phase.")

            {:error, reason} ->
              Format.warn("Could not auto-start: #{inspect(reason)}")
          end

        {:error, reason} ->
          Format.error("Failed to create mission: #{inspect(reason)}")
      end
    else
      goal = if goal == nil or goal == "" do
        answer = safe_gets("What do you want to build? ")
        if answer == "", do: System.halt(0), else: answer
      else
        goal
      end

      quest_result =
        case resolve_sector_id(result_get(result, :options, :sector)) do
          {:ok, cid} -> GiTF.Missions.create(%{goal: goal, sector_id: cid})
          {:error, :no_sector} -> GiTF.Missions.create(%{goal: goal})
        end

      case quest_result do
        {:ok, mission} ->
          Format.success("Quest \"#{mission.name}\" created (#{mission.id})")

          if result_get(result, :flags, :quick) do
            # Quick mode: fast path, no interactive planning
            case GiTF.Major.Orchestrator.start_quest(mission.id, force_fast_path: true) do
              {:ok, phase} ->
                Format.success("Quick run started (phase: #{phase})")
                Format.info("Track progress: gitf mission show #{mission.id}")

              {:error, reason} ->
                Format.error("Failed to start: #{inspect(reason)}")
            end
          else
            GiTF.CLI.PlanHandler.start_interactive_planning(mission)
          end

        {:error, reason} ->
          Format.error("Failed to create mission: #{inspect(reason)}")
      end
    end
  end

  defp dispatch([:mission, :plan], result) do
    id = result_get(result, :args, :id)

    case GiTF.Missions.get(id) do
      {:ok, mission} ->
        GiTF.CLI.PlanHandler.start_interactive_planning(mission)

      {:error, :not_found} ->
        Format.error("Quest not found: #{id}")
    end
  end

  defp dispatch([:mission, :remove], result) do
    id = result_get(result, :args, :id)

    del_result =
      if GiTF.Client.remote?(),
        do: GiTF.Client.delete_quest(id),
        else: GiTF.Missions.kill(id)

    case del_result do
      :ok ->
        Format.success("Quest #{id} removed.")

      {:error, :not_found} ->
        show_not_found_error(:mission, id)
    end
  end

  defp dispatch([:mission, :list], _result) do
    missions =
      if GiTF.Client.remote?() do
        case GiTF.Client.list_quests() do
          {:ok, q} -> q
          {:error, reason} -> Format.error("Remote error: #{inspect(reason)}"); []
        end
      else
        GiTF.Missions.list()
      end

    case missions do
      [] ->
        Format.info("No missions. Create one with `gitf mission \"<goal>\"`.")

      missions ->
        headers = ["ID", "Name", "Phase", "Status", "Sector"]

        rows =
          Enum.map(missions, fn q ->
            sector_name =
              if GiTF.Client.remote?(), do: q[:sector_id] || "-", else: resolve_sector_name(q[:sector_id])
            phase = q[:current_phase] || "-"
            [q[:id], q[:name] || q[:goal] || "-", phase, q[:status] || "pending", sector_name]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:mission, :show], result) do
    id = result_get(result, :args, :id)

    quest_result =
      if GiTF.Client.remote?(),
        do: GiTF.Client.get_quest(id),
        else: GiTF.Missions.get(id)

    case quest_result do
      {:ok, mission} ->
        IO.puts("ID:     #{mission[:id]}")
        IO.puts("Name:   #{mission[:name] || mission[:goal] || "-"}")
        IO.puts("Status: #{mission[:status] || "pending"}")

        if mission[:sector_id] do
          sector_name =
            if GiTF.Client.remote?(), do: mission[:sector_id], else: resolve_sector_name(mission[:sector_id])
          IO.puts("Sector: #{sector_name}")
        end

        if mission[:goal] do
          IO.puts("Goal:   #{mission.goal}")
        end

        IO.puts("")

        unless GiTF.Client.remote?() do
          spec_phases = GiTF.Specs.list_phases(id)

          if spec_phases != [] do
            IO.puts("Specs:  #{Enum.join(spec_phases, ", ")}")
            IO.puts("")
          end
        end

        ops = mission[:ops] || []

        case ops do
          [] ->
            Format.info("No ops in this mission.")

          ops ->
            headers = ["Job ID", "Title", "Status", "Ghost ID"]

            rows =
              Enum.map(ops, fn j ->
                [j.id, j.title, j.status, j[:ghost_id] || "-"]
              end)

            Format.table(headers, rows)
        end

      {:error, :not_found} ->
        show_not_found_error(:mission, id)
    end
  end

  defp dispatch([:ops, :list], _result) do
    ops =
      if GiTF.Client.remote?() do
        case GiTF.Client.list_jobs() do
          {:ok, j} -> j
          {:error, reason} -> Format.error("Remote error: #{inspect(reason)}"); []
        end
      else
        GiTF.Ops.list()
      end

    case ops do
      [] ->
        Format.info("No ops found.")

      ops ->
        headers = ["ID", "Title", "Status", "Quest ID", "Ghost ID"]

        rows =
          Enum.map(ops, fn j ->
            [j.id, j.title, j.status, j[:mission_id], j[:ghost_id] || "-"]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:ops, :show], result) do
    id = result_get(result, :args, :id)

    job_result =
      if GiTF.Client.remote?(),
        do: GiTF.Client.get_job(id),
        else: GiTF.Ops.get(id)

    case job_result do
      {:ok, op} ->
        IO.puts("ID:          #{op.id}")
        IO.puts("Title:       #{op.title}")
        IO.puts("Status:      #{op.status}")
        IO.puts("Quest ID:    #{op[:mission_id]}")
        IO.puts("Sector ID:   #{op[:sector_id]}")
        IO.puts("Ghost ID:    #{op[:ghost_id] || "-"}")
        IO.puts("Created:     #{op[:inserted_at]}")
        IO.puts("")

        if op[:description] do
          IO.puts(op.description)
        end

      {:error, :not_found} ->
        show_not_found_error(:op, id)
        Format.info("Hint: use `gitf ops list` to see all ops.")
    end
  end

  defp dispatch([:ops, :create], result) do
    mission_id = result_get(result, :options, :mission)
    title = result_get(result, :options, :title)
    description = result_get(result, :options, :description)

    case resolve_sector_id(result_get(result, :options, :sector)) do
      {:ok, sector_id} ->
        attrs = %{
          mission_id: mission_id,
          title: title,
          sector_id: sector_id,
          description: description
        }

        case GiTF.Ops.create(attrs) do
          {:ok, op} ->
            Format.success("Job \"#{op.title}\" created (#{op.id})")

          {:error, reason} ->
            Format.error("Failed to create op: #{inspect(reason)}")
        end

      {:error, :no_sector} ->
        Format.error("No sector specified. Use --sector or set one with `gitf sector use`.")
    end
  end

  defp dispatch([:ops, :reset], result) do
    op_id = result_get(result, :args, :id)

    reset_result =
      if GiTF.Client.remote?(),
        do: GiTF.Client.reset_job(op_id),
        else: GiTF.Ops.reset(op_id)

    case reset_result do
      {:ok, op} ->
        Format.success("Job \"#{op.title}\" reset to #{op.status} (#{op.id})")

      {:error, :not_found} ->
        show_not_found_error(:op, op_id)

      {:error, :invalid_transition} ->
        Format.error("Job cannot be reset from its current status.")

      {:error, reason} ->
        Format.error("Failed to reset op: #{inspect(reason)}")
    end
  end

  defp dispatch([:costs, :summary], _result) do
    summary =
      if GiTF.Client.remote?() do
        case GiTF.Client.costs_summary() do
          {:ok, s} -> s
          {:error, reason} ->
            Format.error("Remote error: #{inspect(reason)}")
            System.halt(1)
        end
      else
        GiTF.Costs.summary()
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
      IO.puts("By ghost:")
      headers = ["Ghost ID", "Cost", "Input Tokens", "Output Tokens"]

      rows =
        Enum.map(by_bee, fn {ghost_id, data} ->
          cost = (data[:cost] || 0.0) / 1
          [
            ghost_id,
            "$#{:erlang.float_to_binary(cost, decimals: 4)}",
            "#{data[:input_tokens] || 0}",
            "#{data[:output_tokens] || 0}"
          ]
        end)

      Format.table(headers, rows)
    end
  end

  defp dispatch([:costs, :record], result) do
    if GiTF.Client.remote?() do
      ghost_id = result_get(result, :options, :ghost)
      input = result_get(result, :options, :input)
      output = result_get(result, :options, :output)
      model = result_get(result, :options, :model)

      if is_nil(ghost_id) or is_nil(input) or is_nil(output) do
        Format.error("--ghost, --input, and --output are required (or use --queen)")
      else
        attrs = %{input_tokens: input, output_tokens: output, model: model}

        case GiTF.Client.record_cost(ghost_id, attrs) do
          {:ok, cost} ->
            Format.success("Cost recorded: $#{cost[:cost_usd]} (#{cost[:id]})")

          {:error, reason} ->
            Format.error("Failed to record cost: #{reason}")
        end
      end
    else
      queen? = result_get(result, :flags, :major) || false

      if queen? do
        record_major_costs()
      else
        ghost_id = result_get(result, :options, :ghost)
        input = result_get(result, :options, :input)
        output = result_get(result, :options, :output)
        model = result_get(result, :options, :model)

        if is_nil(ghost_id) or is_nil(input) or is_nil(output) do
          Format.error("--ghost, --input, and --output are required (or use --queen)")
        else
          attrs = %{input_tokens: input, output_tokens: output, model: model}
          {:ok, cost} = GiTF.Costs.record(ghost_id, attrs)

          Format.success(
            "Cost recorded: $#{:erlang.float_to_binary(cost.cost_usd, decimals: 6)} (#{cost.id})"
          )
        end
      end
    end
  end

  defp dispatch([:medic], result) do
    fix? = result_get(result, :flags, :fix) || false
    results = GiTF.Medic.run_all(fix: fix?)

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
    IO.puts(GiTF.CLI.Help.quick_reference())
  end

  defp dispatch([:transfer, :create], result) do
    ghost_id = result_get(result, :options, :ghost)

    case GiTF.Transfer.create(ghost_id) do
      {:ok, link_msg} ->
        Format.success("Transfer created for #{ghost_id} (link_msg #{link_msg.id})")

      {:error, :bee_not_found} ->
        show_not_found_error(:ghost, ghost_id)

      {:error, reason} ->
        Format.error("Transfer failed: #{inspect(reason)}")
    end
  end

  defp dispatch([:transfer, :show], result) do
    ghost_id = result_get(result, :options, :ghost)

    case GiTF.Transfer.detect_handoff(ghost_id) do
      {:ok, link_msg} ->
        IO.puts("Transfer link_msg: #{link_msg.id}")
        IO.puts("Created: #{link_msg.inserted_at}")
        IO.puts("")
        IO.puts(link_msg.body || "(empty)")

      {:error, :no_handoff} ->
        Format.info("No transfer found for #{ghost_id}")
    end
  end

  defp dispatch([:tachikoma], result) do
    if GiTF.Client.remote?() do
      Format.error("This command runs on the server. Run it there directly.")
      return_early()
    end

    no_fix = result_get(result, :flags, :no_fix) || false
    verify = result_get(result, :flags, :verify) || false

    case GiTF.Tachikoma.start_link(auto_fix: !no_fix, verify: verify) do
      {:ok, _pid} ->
        msg = if verify, do: "Tachikoma started with verification enabled", else: "Tachikoma started"
        Format.success("#{msg}. Running health patrols...")
        Process.sleep(:infinity)

      {:error, {:already_started, _pid}} ->
        Format.warn("Tachikoma is already running.")

      {:error, reason} ->
        Format.error("Failed to start Tachikoma: #{inspect(reason)}")
    end
  end

  defp dispatch([:server], result) do
    port = result_get(result, :options, :port) || 4000

    {:ok, _} = Application.ensure_all_started(:gitf)

    url = "http://localhost:#{port}"
    Format.success("GiTF server v#{GiTF.version()} running at #{url}")
    Format.info("API available at #{url}/api/v1/health")
    Format.info("Press Ctrl+C to stop.")

    # Block the main process. The BEAM's exfil handler (Ctrl+C -> 'a')
    # will stop the supervision tree which releases the port.
    ref = Process.monitor(Process.whereis(GiTF.Supervisor))

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    end
  end

  defp dispatch([:dashboard], _result) do
    if GiTF.Client.remote?() do
      Format.error("This command runs on the server. Run it there directly.")
      return_early()
    end

    do_start_dashboard()
  end

  # -- Phase 1: Job dependencies -----------------------------------------------

  defp dispatch([:ops, :deps, :add], result) do
    op_id = result_get(result, :options, :op)
    depends_on = result_get(result, :options, :depends_on)

    case GiTF.Ops.add_dependency(op_id, depends_on) do
      {:ok, dep} ->
        Format.success("Dependency added (#{dep.id}): #{op_id} depends on #{depends_on}")

      {:error, :self_dependency} ->
        Format.error("A op cannot depend on itself.")

      {:error, :cycle_detected} ->
        Format.error("Adding this dependency would create a cycle.")

      {:error, reason} ->
        Format.error("Failed: #{inspect(reason)}")
    end
  end

  defp dispatch([:ops, :deps, :remove], result) do
    op_id = result_get(result, :options, :op)
    depends_on = result_get(result, :options, :depends_on)

    case GiTF.Ops.remove_dependency(op_id, depends_on) do
      :ok -> Format.success("Dependency removed.")
      {:error, :not_found} -> Format.error("Dependency not found.")
    end
  end

  defp dispatch([:ops, :deps, :list], result) do
    op_id = result_get(result, :options, :op)

    deps = GiTF.Ops.dependencies(op_id)
    dependents = GiTF.Ops.dependents(op_id)

    IO.puts("Dependencies of #{op_id}:")

    if deps == [] do
      Format.info("  (none)")
    else
      Enum.each(deps, fn j -> IO.puts("  #{j.id} - #{j.title} [#{j.status}]") end)
    end

    IO.puts("")
    IO.puts("Dependents on #{op_id}:")

    if dependents == [] do
      Format.info("  (none)")
    else
      Enum.each(dependents, fn j -> IO.puts("  #{j.id} - #{j.title} [#{j.status}]") end)
    end

    IO.puts("")
    IO.puts("Ready? #{GiTF.Ops.ready?(op_id)}")
  end

  # -- Phase 2: Budget ---------------------------------------------------------

  defp dispatch([:budget], result) do
    mission_id = result_get(result, :options, :mission)

    budget = GiTF.Budget.budget_for(mission_id)
    spent = GiTF.Budget.spent_for(mission_id)
    remaining = GiTF.Budget.remaining(mission_id)

    IO.puts("Quest:     #{mission_id}")
    IO.puts("Budget:    $#{:erlang.float_to_binary(budget, decimals: 2)}")
    IO.puts("Spent:     $#{:erlang.float_to_binary(spent, decimals: 4)}")
    IO.puts("Remaining: $#{:erlang.float_to_binary(remaining, decimals: 4)}")

    if GiTF.Budget.exceeded?(mission_id) do
      Format.error("BUDGET EXCEEDED")
    else
      pct = if budget > 0, do: Float.round(spent / budget * 100, 1), else: 0.0
      Format.info("#{pct}% of budget used")
    end
  end

  # -- Phase 3: Watch (progress) -----------------------------------------------

  defp dispatch([:watch], _result) do
    GiTF.Progress.init()
    Format.info("Watching ghost progress... (Ctrl+C to stop)")

    Stream.repeatedly(fn ->
      entries = GiTF.Progress.all()

      IO.write(IO.ANSI.clear() <> IO.ANSI.home())
      IO.puts("GiTF Progress (#{length(entries)} active ghosts)")
      IO.puts(String.duplicate("-", 60))

      if entries == [] do
        IO.puts("No active ghosts.")
      else
        Enum.each(entries, fn entry ->
          ghost = entry[:ghost_id] || "?"
          tool = entry[:tool] || "-"
          msg = entry[:message] || ""
          IO.puts("#{ghost}  #{tool}  #{String.slice(msg, 0, 50)}")
        end)
      end

      Process.sleep(1000)
    end)
    |> Stream.run()
  end

  # -- Phase 4: Conflict check ------------------------------------------------

  defp dispatch([:conflict, :check], result) do
    ghost_id = result_get(result, :options, :ghost)

    if ghost_id do
      case GiTF.Ghosts.get(ghost_id) do
        {:ok, ghost} ->
          shell =
            GiTF.Archive.find_one(:shells, fn c -> c.ghost_id == ghost.id and c.status == "active" end)

          if shell do
            case GiTF.Conflict.check(shell.id) do
              {:ok, :clean} ->
                Format.success("No conflicts detected.")

              {:error, :conflicts, files} ->
                Format.warn("Conflicts detected in #{length(files)} file(s):")
                Enum.each(files, fn f -> IO.puts("  #{f}") end)
            end
          else
            Format.info("No active shell for ghost #{ghost_id}")
          end

        {:error, :not_found} ->
          show_not_found_error(:ghost, ghost_id)
      end
    else
      results = GiTF.Conflict.check_all_active()

      if results == [] do
        Format.info("No active shells to check.")
      else
        Enum.each(results, fn
          {:ok, shell_id, :clean} ->
            IO.puts("#{shell_id}: clean")

          {:error, shell_id, :conflicts, files} ->
            Format.warn("#{shell_id}: conflicts in #{Enum.join(files, ", ")}")
        end)
      end
    end
  end

  # -- Phase 5: Validate ------------------------------------------------------

  defp dispatch([:validate], result) do
    ghost_id = result_get(result, :options, :ghost)

    with {:ok, ghost} <- GiTF.Ghosts.get(ghost_id),
         {:ok, op} <- GiTF.Ops.get(ghost.op_id) do
      shell = GiTF.Archive.find_one(:shells, fn c -> c.ghost_id == ghost.id and c.status == "active" end)

      if shell do
        Format.info("Running validation for ghost #{ghost_id}...")

        case GiTF.Validator.validate(ghost_id, op, shell.id) do
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
        Format.info("No active shell for ghost #{ghost_id}")
      end
    else
      {:error, :not_found} -> Format.error("Ghost or op not found: #{ghost_id}")
      {:error, reason} -> Format.error("Failed: #{inspect(reason)}")
    end
  end

  # -- Phase 6: GitHub ---------------------------------------------------------

  defp dispatch([:github, :pr], result) do
    ghost_id = result_get(result, :options, :ghost)

    with {:ok, ghost} <- GiTF.Ghosts.get(ghost_id),
         {:ok, op} <- GiTF.Ops.get(ghost.op_id) do
      shell = GiTF.Archive.find_one(:shells, fn c -> c.ghost_id == ghost.id end)
      sector = shell && GiTF.Archive.get(:sectors, shell.sector_id)

      cond do
        is_nil(shell) ->
          Format.error("No shell found for ghost #{ghost_id}")

        is_nil(sector) ->
          show_not_found_error(:sector, "unknown")

        is_nil(Map.get(sector, :github_owner)) || is_nil(Map.get(sector, :github_repo)) ->
          Format.error(
            "Sector #{sector.name} has no GitHub config. Use --github-owner and --github-repo when adding."
          )

        true ->
          case GiTF.GitHub.create_pr(sector, shell, op) do
            {:ok, url} -> Format.success("PR created: #{url}")
            {:error, reason} -> Format.error("PR creation failed: #{inspect(reason)}")
          end
      end
    else
      {:error, :not_found} -> Format.error("Ghost or op not found: #{ghost_id}")
      {:error, reason} -> Format.error("Failed: #{inspect(reason)}")
    end
  end

  defp dispatch([:github, :issues], result) do
    case resolve_sector_id(result_get(result, :options, :sector)) do
      {:ok, sector_id} ->
        case GiTF.Sector.get(sector_id) do
          {:ok, sector} ->
            case GiTF.GitHub.list_issues(sector) do
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
            show_not_found_error(:sector, sector_id)
        end

      {:error, :no_sector} ->
        Format.error("No sector specified. Use --sector or set one with `gitf sector use`.")
    end
  end

  defp dispatch([:github, :run], result) do
    issue_number = result_get(result, :args, :issue)
    quick = result_get(result, :flags, :quick) || false

    case resolve_sector_id(result_get(result, :options, :sector)) do
      {:ok, sector_id} ->
        case GiTF.Sector.get(sector_id) do
          {:ok, sector} ->
            Format.info("Fetching issue ##{issue_number}...")

            case GiTF.GitHub.create_mission_from_issue(sector, issue_number, quick: quick) do
              {:ok, mission} ->
                Format.success("Mission \"#{mission.name}\" created from issue ##{issue_number}")
                Format.info("Track progress: gitf mission show #{mission.id}")

              {:error, :issue_not_found} ->
                Format.error("Issue ##{issue_number} not found")

              {:error, :no_github_config} ->
                Format.error("Sector #{sector.name} has no GitHub config. Use --github-owner and --github-repo when adding.")

              {:error, reason} ->
                Format.error("Failed: #{inspect(reason)}")
            end

          {:error, _} ->
            show_not_found_error(:sector, sector_id)
        end

      {:error, :no_sector} ->
        Format.error("No sector specified. Use --sector or set one with `gitf sector use`.")
    end
  end

  # `github sync` is an alias for `github issues` (kept for backward compatibility)
  defp dispatch([:github, :sync], result), do: dispatch([:github, :issues], result)

  defp dispatch([:mission, :spec, :write], result) do
    mission_id = result_get(result, :args, :mission_id)
    phase = result_get(result, :options, :phase)
    content = result_get(result, :options, :content)

    if GiTF.Client.remote?() do
      content = content || IO.read(:stdio, :eof)

      case GiTF.Client.quest_spec_write(mission_id, phase, content) do
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

      case GiTF.Specs.write(mission_id, phase, content) do
        {:ok, path} ->
          Format.success("Spec written: #{path}")

        {:error, {:invalid_phase, p}} ->
          Format.error("Invalid phase: #{p}. Valid phases: #{Enum.join(GiTF.Specs.phases(), ", ")}")

        {:error, reason} ->
          Format.error("Failed to write spec: #{format_error(reason)}")
      end
    end
  end

  defp dispatch([:mission, :spec, :show], result) do
    mission_id = result_get(result, :args, :mission_id)
    phase = result_get(result, :options, :phase)

    if GiTF.Client.remote?() do
      case GiTF.Client.quest_spec(mission_id, phase) do
        {:ok, data} -> IO.puts(data[:content] || inspect(data))
        {:error, :not_found} -> Format.error("No #{phase} spec found for mission #{mission_id}")
        {:error, reason} -> Format.error("Failed: #{format_error(reason)}")
      end
    else
      case GiTF.Specs.read(mission_id, phase) do
        {:ok, content} ->
          IO.puts(content)

        {:error, :not_found} ->
          Format.error("No #{phase} spec found for mission #{mission_id}")

        {:error, {:invalid_phase, p}} ->
          Format.error("Invalid phase: #{p}. Valid phases: #{Enum.join(GiTF.Specs.phases(), ", ")}")
      end
    end
  end

  defp dispatch([:mission, :status], result) do
    mission_id = result_get(result, :args, :mission_id)

    status_result =
      if GiTF.Client.remote?(),
        do: GiTF.Client.quest_status(mission_id),
        else: GiTF.Major.Orchestrator.get_quest_status(mission_id)

    case status_result do
      {:ok, status} ->
        mission = status[:mission] || %{}
        Format.info("Quest: #{mission[:name]} (#{mission[:id]})")
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
        Format.error("Failed to get mission status: #{inspect(reason)}")
    end
  end

  defp dispatch([:completions], result) do
    shell = result_get(result, :args, :shell) || "bash"

    case shell do
      s when s in ["bash", "zsh", "fish"] ->
        IO.puts(GiTF.CLI.Completions.generate(String.to_atom(s)))

      other ->
        Format.error("Unknown shell: #{other}. Supported: bash, zsh, fish")
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

  defp record_major_costs do
    # Read costs from the latest Major transcript if available
    case GiTF.gitf_dir() do
      {:ok, root} ->
        transcript_dir = Path.join([root, ".gitf", "major", ".claude", "projects"])

        costs = extract_costs_from_transcripts(transcript_dir)

        if costs.input_tokens > 0 or costs.output_tokens > 0 do
          attrs = %{
            input_tokens: costs.input_tokens,
            output_tokens: costs.output_tokens,
            cache_read_tokens: costs.cache_read_tokens,
            cache_write_tokens: costs.cache_write_tokens,
            model: costs.model
          }

          {:ok, cost} = GiTF.Costs.record("major", attrs)
          Format.success(
            "Major cost recorded: $#{:erlang.float_to_binary(cost.cost_usd, decimals: 6)} (#{cost.id})"
          )
        else
          Format.info("No new queen costs to record.")
        end

      {:error, _} ->
        Format.error("Not in a gitf workspace.")
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
  defp show_not_found_error(:ghost, id),
    do: IO.puts(GiTF.CLI.Errors.format_error(:bee_not_found, %{ghost_id: id}))

  defp show_not_found_error(:mission, id),
    do: IO.puts(GiTF.CLI.Errors.format_error(:quest_not_found, %{mission_id: id}))

  defp show_not_found_error(:op, id),
    do: IO.puts(GiTF.CLI.Errors.format_error(:job_not_found, %{op_id: id}))

  defp show_not_found_error(:sector, id),
    do: IO.puts(GiTF.CLI.Errors.format_error(:comb_not_found, %{sector_id: id}))

  defp resolve_sector_id(explicit) when is_binary(explicit), do: {:ok, explicit}

  defp resolve_sector_id(nil) do
    case GiTF.Sector.current() do
      {:ok, sector} -> {:ok, sector.id}
      {:error, :no_current_sector} -> {:error, :no_sector}
    end
  end

  defp resolve_sector_name(nil), do: "-"

  defp resolve_sector_name(sector_id) do
    case GiTF.Sector.get(sector_id) do
      {:ok, sector} -> sector.name
      _ -> sector_id
    end
  end

  defp do_prime_major do
    case GiTF.gitf_dir() do
      {:ok, gitf_root} ->
        case GiTF.Brief.brief(:major, gitf_root) do
          {:ok, markdown} -> IO.puts(markdown)
          {:error, reason} -> Format.error("Brief failed: #{inspect(reason)}")
        end

      {:error, :not_in_gitf} ->
        IO.puts(GiTF.CLI.Errors.format_error(:store_not_initialized))
    end
  end

  defp do_prime_bee(ghost_id) do
    case GiTF.Brief.brief(:ghost, ghost_id) do
      {:ok, markdown} -> IO.puts(markdown)
      {:error, :bee_not_found} -> show_not_found_error(:ghost, ghost_id)
      {:error, reason} -> Format.error("Brief failed: #{inspect(reason)}")
    end
  end

  defp do_start_dashboard do
    port =
      Application.get_env(:gitf, GiTF.Web.Endpoint)
      |> Keyword.get(:http, [])
      |> Keyword.get(:port, 4000)

    url = "http://localhost:#{port}/dashboard"
    Format.success("Dashboard available at #{url}")
    Format.info("The web server runs on port #{port} (shared with the API).")
  end

  defp discover_nearby_repos do
    cwd = File.cwd!()

    current =
      if GiTF.Git.repo?(cwd),
        do: [{". (current directory)", cwd}],
        else: []

    subdirs =
      case File.ls(cwd) do
        {:ok, entries} ->
          entries
          |> Enum.sort()
          |> Enum.filter(fn entry ->
            full = Path.join(cwd, entry)
            File.dir?(full) and not String.starts_with?(entry, ".") and GiTF.Git.repo?(full)
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
      name: "gitf",
      description: "The GiTF - Multi-agent orchestration for AI coding assistants",
      version: GiTF.version(),
      about: "Coordinate multiple AI coding assistants working on a shared codebase.",
      subcommands: [
        medic: [
          name: "medic",
          about: "Check system prerequisites and GiTF health",
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
        completions: [
          name: "completions",
          about: "Generate shell completion scripts (bash, zsh, fish)",
          args: [
            shell: [
              value_name: "SHELL",
              help: "Shell type: bash, zsh, or fish",
              required: false,
              parser: :string
            ]
          ]
        ],
        sector: [
          name: "sector",
          about: "Manage codebases (sectors) tracked by this section",
          subcommands: [
            add: [
              name: "add",
              about: "Register a codebase with the section",
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
                  help: "Human-friendly name for the sector",
                  parser: :string,
                  required: false
                ],
                sync_strategy: [
                  long: "--sync-strategy",
                  help: "Sync strategy: manual, auto_merge, or pr_branch (default: manual)",
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
              about: "List all registered sectors"
            ],
            remove: [
              name: "remove",
              about: "Unregister a sector from the section",
              args: [
                name: [
                  value_name: "NAME",
                  help: "Name of the sector to remove",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            use: [
              name: "use",
              about: "Set the current working sector",
              args: [
                name: [
                  value_name: "NAME",
                  help: "Name or ID of the sector to set as current",
                  required: false,
                  parser: :string
                ]
              ]
            ],
            rename: [
              name: "rename",
              about: "Rename a sector and update all tracking references",
              args: [
                name: [
                  value_name: "NAME",
                  help: "Current name or ID of the sector",
                  required: true,
                  parser: :string
                ],
                new_name: [
                  value_name: "NEW_NAME",
                  help: "New name for the sector",
                  required: true,
                  parser: :string
                ]
              ]
            ]
          ]
        ],
        run: [
          name: "run",
          about: "Quick-run a focused task (bug fix, single feature). Skips the full phase pipeline.",
          args: [
            goal: [
              value_name: "GOAL",
              help: "What to do, e.g. \"fix the login bug\" or \"add pagination to the users endpoint\"",
              required: true,
              parser: :string
            ]
          ],
          options: [
            sector: [
              short: "-c",
              long: "--sector",
              help: "Sector ID (defaults to current sector)",
              parser: :string,
              required: false
            ]
          ]
        ],
        queen: [
          name: "major",
          about: "Start the queen orchestrator for a mission"
        ],
        ghost: [
          name: "ghost",
          about: "Manage ghost worker agents",
          subcommands: [
            list: [
              name: "list",
              about: "List all ghosts and their status"
            ],
            spawn: [
              name: "spawn",
              about: "Spawn a new ghost to work on a op",
              options: [
                op: [
                  short: "-j",
                  long: "--op",
                  help: "Job ID to assign to the ghost",
                  parser: :string,
                  required: true
                ],
                sector: [
                  short: "-c",
                  long: "--sector",
                  help: "Sector ID (repository) to work in (defaults to current sector)",
                  parser: :string,
                  required: false
                ],
                name: [
                  short: "-n",
                  long: "--name",
                  help: "Custom name for the ghost",
                  parser: :string,
                  required: false
                ]
              ]
            ],
            stop: [
              name: "stop",
              about: "Stop a running ghost",
              options: [
                id: [
                  long: "--id",
                  help: "Ghost ID to stop",
                  parser: :string,
                  required: true
                ]
              ]
            ],
            complete: [
              name: "complete",
              about: "Mark a ghost as completed (used by wrapper scripts)",
              args: [
                ghost_id: [
                  value_name: "GHOST_ID",
                  help: "Ghost ID to mark as completed",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            fail: [
              name: "fail",
              about: "Mark a ghost as failed (used by wrapper scripts)",
              args: [
                ghost_id: [
                  value_name: "GHOST_ID",
                  help: "Ghost ID to mark as failed",
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
                "Revive a dead ghost — spawn a new ghost into its existing worktree to finish the work",
              args: [
                ghost_id: [
                  value_name: "GHOST_ID",
                  help: "ID of the dead ghost whose worktree to reuse",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            context: [
              name: "context",
              about: "Show context usage statistics for a ghost",
              args: [
                ghost_id: [
                  value_name: "GHOST_ID",
                  help: "Ghost ID to check context usage",
                  required: true,
                  parser: :string
                ]
              ]
            ]
          ]
        ],
        mission: [
          name: "mission",
          about: "Manage missions (high-level objectives)",
          subcommands: [
            new: [
              name: "new",
              about: "Create a new mission with interactive planning session",
              args: [
                goal: [
                  value_name: "GOAL",
                  help: "The goal for this mission (omit for discovery mode)",
                  required: false,
                  parser: :string
                ]
              ],
              options: [
                sector: [
                  short: "-c",
                  long: "--sector",
                  help: "Sector ID (defaults to current sector)",
                  parser: :string,
                  required: false
                ]
              ],
              flags: [
                quick: [
                  short: "-q",
                  long: "--quick",
                  help: "Skip full pipeline — create a single op and go (for bug fixes, focused tasks)"
                ]
              ]
            ],
            list: [
              name: "list",
              about: "List all missions"
            ],
            show: [
              name: "show",
              about: "Show mission details",
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
              about: "Remove a mission",
              args: [
                id: [
                  value_name: "ID",
                  help: "Quest ID to remove",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            sync: [
              name: "sync",
              about: "Sync all completed ghost branches into a mission branch",
              args: [
                id: [
                  value_name: "ID",
                  help: "Quest ID to sync",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            report: [
              name: "report",
              about: "Show performance report for a mission run",
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
              about: "Close a mission and remove associated shells/worktrees",
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
              about: "Start or resume interactive planning for a mission",
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
              about: "Manage mission planning specs (requirements, design, tasks)",
              subcommands: [
                write: [
                  name: "write",
                  about: "Write a spec phase for a mission",
                  args: [
                    mission_id: [
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
                  about: "Show a spec phase for a mission",
                  args: [
                    mission_id: [
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
              about: "Show mission phase status and progress",
              args: [
                mission_id: [
                  value_name: "QUEST_ID",
                  help: "Quest identifier",
                  required: true,
                  parser: :string
                ]
              ]
            ]
          ]
        ],
        ops: [
          name: "ops",
          about: "List and inspect ops in the current mission",
          subcommands: [
            list: [
              name: "list",
              about: "List all ops in a mission"
            ],
            show: [
              name: "show",
              about: "Show op details",
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
              about: "Create a new op",
              options: [
                mission: [
                  short: "-q",
                  long: "--mission",
                  help: "Quest ID to attach the op to",
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
                sector: [
                  short: "-c",
                  long: "--sector",
                  help: "Sector ID for the op (defaults to current sector)",
                  parser: :string,
                  required: false
                ],
                description: [
                  short: "-d",
                  long: "--description",
                  help: "Detailed op description",
                  parser: :string,
                  required: false
                ]
              ]
            ],
            reset: [
              name: "reset",
              about: "Reset a stuck op back to pending",
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
              about: "Manage op dependencies",
              subcommands: [
                add: [
                  name: "add",
                  about: "Add a dependency between ops",
                  options: [
                    op: [
                      short: "-j",
                      long: "--op",
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
                  about: "Remove a dependency between ops",
                  options: [
                    op: [
                      short: "-j",
                      long: "--op",
                      help: "Job ID",
                      parser: :string,
                      required: true
                    ],
                    depends_on: [
                      long: "--depends-on",
                      help: "Dependency op ID to remove",
                      parser: :string,
                      required: true
                    ]
                  ]
                ],
                list: [
                  name: "list",
                  about: "List dependencies for a op",
                  options: [
                    op: [
                      short: "-j",
                      long: "--op",
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
        link_msg: [
          name: "link_msg",
          about: "View inter-agent messages (links)",
          subcommands: [
            list: [
              name: "list",
              about: "List recent link_msg messages",
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
              about: "Show a specific link_msg message",
              args: [
                id: [
                  value_name: "ID",
                  help: "Link message identifier",
                  required: true,
                  parser: :string
                ]
              ]
            ],
            send: [
              name: "send",
              about: "Send a link_msg message",
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
                ghost: [
                  short: "-b",
                  long: "--ghost",
                  help: "Ghost ID to record costs for",
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
        shell: [
          name: "shell",
          about: "Manage git worktree shells",
          subcommands: [
            list: [
              name: "list",
              about: "List active shells (worktrees)"
            ],
            clean: [
              name: "clean",
              about: "Remove stale shells"
            ]
          ]
        ],
        tachikoma: [
          name: "tachikoma",
          about: "Start the health patrol tachikoma",
          flags: [
            no_fix: [
              long: "--no-fix",
              help: "Disable auto-fixing of issues"
            ],
            verify: [
              long: "--verify",
              help: "Enable automatic op verification"
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
              help: "Sector name (defaults to directory name)",
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
              help: "Preview detection results without creating sector"
            ]
          ]
        ],
        verify: [
          name: "verify",
          about: "Verify completed op work",
          options: [
            op: [
              short: "-j",
              long: "--op",
              help: "Job ID to verify",
              parser: :string,
              required: false
            ],
            mission: [
              short: "-q",
              long: "--mission",
              help: "Verify all ops in a mission",
              parser: :string,
              required: false
            ]
          ]
        ],
        accept: [
          name: "accept",
          about: "Test acceptance criteria for ops or missions",
          options: [
            op: [
              short: "-j",
              long: "--op",
              help: "Job ID to test",
              parser: :string,
              required: false
            ],
            mission: [
              short: "-q",
              long: "--mission",
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
            op: [
              short: "-j",
              long: "--op",
              help: "Job ID to check",
              parser: :string,
              required: false
            ],
            mission: [
              short: "-q",
              long: "--mission",
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
            op: [
              short: "-j",
              long: "--op",
              help: "Job ID for quality check or baseline source",
              parser: :string,
              required: false
            ],
            mission: [
              short: "-q",
              long: "--mission",
              help: "Quest ID for quality report",
              parser: :string,
              required: false
            ],
            sector: [
              short: "-c",
              long: "--sector",
              help: "Sector ID for baseline management",
              parser: :string,
              required: false
            ]
          ]
        ],
        intel: [
          name: "intel",
          about: "Adaptive intel and failure analysis",
          args: [
            subcommand: [
              help: "Subcommand: analyze, retry, insights, learn, best-practices, recommend",
              parser: :string,
              required: true
            ]
          ],
          options: [
            op: [
              short: "-j",
              long: "--op",
              help: "Job ID for analysis or retry",
              parser: :string,
              required: false
            ],
            sector: [
              short: "-c",
              long: "--sector",
              help: "Sector ID for insights or learning",
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
            sector: [
              short: "-c",
              long: "--sector",
              help: "Sector ID for issue prediction",
              parser: :string,
              required: false
            ]
          ]
        ],
        deadlock: [
          name: "deadlock",
          about: "Detect and resolve dependency deadlocks",
          options: [
            mission: [
              short: "-q",
              long: "--mission",
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
          about: "Start the GiTF web server for real-time mission monitoring",
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
        transfer: [
          name: "transfer",
          about: "Manage context-preserving ghost transfers",
          subcommands: [
            create: [
              name: "create",
              about: "Create a transfer for a ghost",
              options: [
                ghost: [
                  short: "-b",
                  long: "--ghost",
                  help: "Ghost ID to create transfer for",
                  parser: :string,
                  required: true
                ]
              ]
            ],
            show: [
              name: "show",
              about: "Show transfer context for a ghost",
              options: [
                ghost: [
                  short: "-b",
                  long: "--ghost",
                  help: "Ghost ID to show transfer for",
                  parser: :string,
                  required: true
                ]
              ]
            ]
          ]
        ],
        brief: [
          name: "brief",
          about: "Output context prompt for a Major or Ghost session",
          flags: [
            queen: [
              long: "--queen",
              help: "Brief the Major with instructions and section state"
            ]
          ],
          options: [
            ghost: [
              short: "-b",
              long: "--ghost",
              help: "Ghost ID to brief with op context",
              parser: :string,
              required: false
            ]
          ]
        ],
        budget: [
          name: "budget",
          about: "Show budget status for a mission",
          options: [
            mission: [
              short: "-q",
              long: "--mission",
              help: "Quest ID to check budget for",
              parser: :string,
              required: true
            ]
          ]
        ],
        watch: [
          name: "watch",
          about: "Watch real-time ghost progress"
        ],
        conflict: [
          name: "conflict",
          about: "Check for merge conflicts",
          subcommands: [
            check: [
              name: "check",
              about: "Check for merge conflicts in active shells",
              options: [
                ghost: [
                  short: "-b",
                  long: "--ghost",
                  help: "Ghost ID to check (optional, checks all if omitted)",
                  parser: :string,
                  required: false
                ]
              ]
            ]
          ]
        ],
        validate: [
          name: "validate",
          about: "Run validation on a ghost's completed work",
          options: [
            ghost: [
              short: "-b",
              long: "--ghost",
              help: "Ghost ID to validate",
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
              about: "Create a GitHub PR for a ghost's work",
              options: [
                ghost: [
                  short: "-b",
                  long: "--ghost",
                  help: "Ghost ID to create PR for",
                  parser: :string,
                  required: true
                ]
              ]
            ],
            issues: [
              name: "issues",
              about: "List GitHub issues for a sector",
              options: [
                sector: [
                  short: "-c",
                  long: "--sector",
                  help: "Sector ID (defaults to current sector)",
                  parser: :string,
                  required: false
                ]
              ]
            ],
            run: [
              name: "run",
              about: "Create a mission from a GitHub issue and start working on it",
              args: [
                issue: [
                  value_name: "ISSUE_NUMBER",
                  help: "GitHub issue number (e.g. 42)",
                  required: true,
                  parser: :integer
                ]
              ],
              options: [
                sector: [
                  short: "-c",
                  long: "--sector",
                  help: "Sector ID (defaults to current sector)",
                  parser: :string,
                  required: false
                ]
              ],
              flags: [
                quick: [
                  short: "-q",
                  long: "--quick",
                  help: "Use fast path (single ghost, skip full pipeline)"
                ]
              ]
            ],
            sync: [
              name: "sync",
              about: "Sync GitHub issues for a sector",
              options: [
                sector: [
                  short: "-c",
                  long: "--sector",
                  help: "Sector ID to sync (defaults to current sector)",
                  parser: :string,
                  required: false
                ]
              ]
            ]
          ]
        ],
        version: [
          name: "version",
          about: "Print the GiTF version"
        ],
        verify: [
          name: "verify",
          about: "Verify completed ops",
          options: [
            op: [
              short: "-j",
              long: "--op",
              help: "Job ID to verify",
              parser: :string,
              required: false
            ],
            mission: [
              short: "-q",
              long: "--mission",
              help: "Quest ID to verify all ops",
              parser: :string,
              required: false
            ]
          ]
        ]
      ]
    )
  end
end
