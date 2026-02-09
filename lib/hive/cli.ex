defmodule Hive.CLI do
  @moduledoc "Escript entry point. Parses argv and dispatches to subcommand handlers."

  alias Hive.CLI.Format

  # -- Escript entry point ----------------------------------------------------

  @spec main([String.t()]) :: no_return()
  def main(argv) do
    argv = expand_defaults(argv)
    optimus = build_optimus!()

    case Optimus.parse(optimus, argv) do
      {:ok, _result} ->
        Optimus.Help.help(optimus, [], 80) |> Enum.each(&IO.puts/1)

      {:ok, subcommand_path, result} ->
        maybe_ensure_store(subcommand_path)
        dispatch(subcommand_path, result)

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

  @quest_subcommands ~w(new list show delete merge report close)

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
  @no_auto_store [[:init], [:version]]

  defp maybe_ensure_store(subcommand_path) do
    unless subcommand_path in @no_auto_store do
      ensure_store()
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
        :skip
    end
  end

  # -- Command dispatch -------------------------------------------------------
  #
  # All dispatch/2 clauses are grouped together to satisfy Elixir's
  # clause-grouping requirement. Helper functions follow after.

  defp dispatch([:version], _result) do
    IO.puts("hive #{Hive.version()}")
  end

  defp dispatch([:init], result) do
    IO.puts("hive v#{Hive.version()}")
    path = result_get(result, :args, :path) || "."
    force? = result_get(result, :flags, :force) || false
    quick? = result_get(result, :flags, :quick) || false

    if quick? do
      do_quick_init(path, force?)
    else
      case Hive.Init.init(path, force: force?) do
        {:ok, expanded} ->
          Format.success("Hive initialized at #{expanded}")

        {:error, :already_initialized} ->
          Format.error("Already initialized. Use --force to reinitialize.")

        {:error, reason} ->
          Format.error("Init failed: #{inspect(reason)}")
      end
    end
  end

  defp dispatch([:comb, :add], result) do
    path = result_get(result, :args, :path)

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

    name = result_get(result, :options, :name)
    merge_strategy = result_get(result, :options, :merge_strategy)
    validation_command = result_get(result, :options, :validation_command)
    github_owner = result_get(result, :options, :github_owner)
    github_repo = result_get(result, :options, :github_repo)

    opts = []
    opts = if name, do: Keyword.put(opts, :name, name), else: opts
    opts = if merge_strategy, do: Keyword.put(opts, :merge_strategy, merge_strategy), else: opts
    opts = if validation_command, do: Keyword.put(opts, :validation_command, validation_command), else: opts
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

  defp dispatch([:comb, :list], _result) do
    case Hive.Comb.list() do
      [] ->
        Format.info("No combs registered. Use `hive comb add <path>` to register one.")

      combs ->
        current_id =
          case Hive.Comb.current() do
            {:ok, c} -> c.id
            _ -> nil
          end

        headers = ["", "ID", "Name", "Path"]

        rows =
          Enum.map(combs, fn c ->
            marker = if c.id == current_id, do: "*", else: ""
            [marker, c.id, c.name, c.path || c.repo_url || "-"]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:comb, :remove], result) do
    name = result_get(result, :args, :name)

    case Hive.Comb.remove(name) do
      {:ok, comb} ->
        Format.success("Comb \"#{comb.name}\" removed.")

      {:error, :not_found} ->
        Format.error("Comb not found: #{name}")
        Format.info("Hint: use `hive comb list` to see all combs.")
    end
  end

  defp dispatch([:comb, :use], result) do
    name = result_get(result, :args, :name)

    if name do
      case Hive.Comb.set_current(name) do
        {:ok, comb} ->
          Format.success("Current comb set to \"#{comb.name}\" (#{comb.id})")

        {:error, :not_found} ->
          Format.error("Comb not found: #{name}")
          Format.info("Hint: use `hive comb list` to see all combs.")

        {:error, reason} ->
          Format.error("Failed to set current comb: #{inspect(reason)}")
      end
    else
      case Hive.Comb.list() do
        [] ->
          Format.error("No combs registered. Use `hive comb add <path>` to register one.")

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

    cond do
      queen? ->
        do_prime_queen()

      is_binary(bee_id) ->
        do_prime_bee(bee_id)

      true ->
        Format.error("Specify --queen or --bee <id>")
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
        Format.error("Not inside a hive workspace. Run `hive init` first.")
        Format.info("Hint: use `hive init` or `hive init --quick` to create a workspace.")
    end
  end

  defp dispatch([:bee, :list], _result) do
    case Hive.Bees.list() do
      [] ->
        Format.info("No bees. Bees are spawned when the Queen assigns jobs.")

      bees ->
        headers = ["ID", "Name", "Status", "Job ID"]

        rows =
          Enum.map(bees, fn b ->
            [b.id, b.name, b.status, b.job_id || "-"]
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
            Format.error("Not inside a hive workspace. Run `hive init` first.")

          {:error, :not_found} ->
            Format.error("Comb not found: #{comb_id}")

          {:error, reason} ->
            Format.error("Failed: #{inspect(reason)}")
        end

      {:error, :no_comb} ->
        Format.error("No comb specified. Use --comb or set one with `hive comb use`.")
    end
  end

  defp dispatch([:bee, :stop], result) do
    bee_id = result_get(result, :options, :id)

    case Hive.Bees.stop(bee_id) do
      :ok ->
        Format.success("Bee #{bee_id} stopped.")

      {:error, :not_found} ->
        Format.error("Bee not found or not running: #{bee_id}")
        Format.info("Hint: use `hive bee list` to see all bees.")
    end
  end

  defp dispatch([:bee, :complete], result) do
    bee_id = result_get(result, :args, :bee_id)

    case Hive.Bees.get(bee_id) do
      {:ok, bee} ->
        Hive.Store.put(:bees, %{bee | status: "stopped"})
        if bee.job_id do
          Hive.Jobs.complete(bee.job_id)
          Hive.Jobs.unblock_dependents(bee.job_id)
          Hive.Waggle.send(bee_id, "queen", "job_complete", "Job #{bee.job_id} completed successfully")
        end
        Format.success("Bee #{bee_id} marked as completed.")

      {:error, _} ->
        Format.error("Bee not found: #{bee_id}")
    end
  end

  defp dispatch([:bee, :fail], result) do
    bee_id = result_get(result, :args, :bee_id)
    reason = result_get(result, :options, :reason) || "unknown"

    case Hive.Bees.get(bee_id) do
      {:ok, bee} ->
        Hive.Store.put(:bees, %{bee | status: "crashed"})
        if bee.job_id do
          Hive.Jobs.fail(bee.job_id)
          Hive.Waggle.send(bee_id, "queen", "job_failed", "Job #{bee.job_id} failed: #{reason}")
        end
        Format.success("Bee #{bee_id} marked as failed: #{reason}")

      {:error, _} ->
        Format.error("Bee not found: #{bee_id}")
    end
  end

  defp dispatch([:bee, :revive], result) do
    dead_bee_id = result_get(result, :args, :bee_id)

    with {:ok, hive_root} <- Hive.hive_dir() do
      case Hive.Bees.revive(dead_bee_id, hive_root) do
        {:ok, bee} ->
          Format.success("Revived into bee \"#{bee.name}\" (#{bee.id}) using #{dead_bee_id}'s worktree")

        {:error, reason} ->
          Format.error("Failed to revive: #{inspect(reason)}")
      end
    else
      {:error, :not_in_hive} ->
        Format.error("Not inside a hive workspace. Run `hive init` first.")
    end
  end

  defp dispatch([:quest, :report], result) do
    id = result_get(result, :args, :id)

    case Hive.Report.generate(id) do
      {:ok, report} ->
        IO.puts(Hive.Report.format(report))

      {:error, :not_found} ->
        Format.error("Quest not found: #{id}")

      {:error, reason} ->
        Format.error("Report failed: #{inspect(reason)}")
    end
  end

  defp dispatch([:quest, :merge], result) do
    id = result_get(result, :args, :id)

    case Hive.Merge.merge_quest(id) do
      {:ok, branch} ->
        Format.success("All bee branches merged into #{branch}")

      {:error, :not_found} ->
        Format.error("Quest not found: #{id}")

      {:error, :no_cells} ->
        Format.error("No active cells to merge for this quest.")

      {:error, {:merge_conflicts, branch, failed}} ->
        Format.warn("Merged into #{branch} with conflicts in: #{Enum.join(failed, ", ")}")

      {:error, reason} ->
        Format.error("Quest merge failed: #{inspect(reason)}")
    end
  end

  defp dispatch([:quest, :close], result) do
    id = result_get(result, :args, :id)

    case Hive.Quests.close(id) do
      {:ok, quest} ->
        Format.success("Quest \"#{quest.name}\" closed. Associated cells removed.")

      {:error, :not_found} ->
        Format.error("Quest not found: #{id}")
        Format.info("Hint: use `hive quest list` to see all quests.")
    end
  end

  defp dispatch([:quest, :new], result) do
    goal = result_get(result, :args, :goal)

    case resolve_comb_id(result_get(result, :options, :comb)) do
      {:ok, comb_id} ->
        attrs = %{goal: goal, comb_id: comb_id}

        case Hive.Quests.create(attrs) do
          {:ok, quest} ->
            Format.success("Quest \"#{quest.name}\" created (#{quest.id})")

          {:error, reason} ->
            Format.error("Failed to create quest: #{inspect(reason)}")
        end

      {:error, :no_comb} ->
        case Hive.Quests.create(%{goal: goal}) do
          {:ok, quest} ->
            Format.success("Quest \"#{quest.name}\" created (#{quest.id})")

          {:error, reason} ->
            Format.error("Failed to create quest: #{inspect(reason)}")
        end
    end
  end

  defp dispatch([:quest, :delete], result) do
    id = result_get(result, :args, :id)

    case Hive.Quests.delete(id) do
      :ok ->
        Format.success("Quest #{id} deleted.")

      {:error, :not_found} ->
        Format.error("Quest not found: #{id}")
        Format.info("Hint: use `hive quest list` to see all quests.")
    end
  end

  defp dispatch([:quest, :list], _result) do
    case Hive.Quests.list() do
      [] ->
        Format.info("No quests. Create one with `hive quest \"<goal>\"`.")

      quests ->
        headers = ["ID", "Name", "Status", "Comb"]

        rows =
          Enum.map(quests, fn q ->
            comb_name = resolve_comb_name(q[:comb_id])
            [q.id, q.name, q.status, comb_name]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:quest, :show], result) do
    id = result_get(result, :args, :id)

    case Hive.Quests.get(id) do
      {:ok, quest} ->
        IO.puts("ID:     #{quest.id}")
        IO.puts("Name:   #{quest.name}")
        IO.puts("Status: #{quest.status}")

        if quest[:comb_id] do
          comb_name = resolve_comb_name(quest.comb_id)
          IO.puts("Comb:   #{comb_name}")
        end

        if quest[:goal] do
          IO.puts("Goal:   #{quest.goal}")
        end

        IO.puts("")

        case quest.jobs do
          [] ->
            Format.info("No jobs in this quest.")

          jobs ->
            headers = ["Job ID", "Title", "Status", "Bee ID"]

            rows =
              Enum.map(jobs, fn j ->
                [j.id, j.title, j.status, j.bee_id || "-"]
              end)

            Format.table(headers, rows)
        end

      {:error, :not_found} ->
        Format.error("Quest not found: #{id}")
        Format.info("Hint: use `hive quest list` to see all quests.")
    end
  end

  defp dispatch([:jobs, :list], _result) do
    case Hive.Jobs.list() do
      [] ->
        Format.info("No jobs found.")

      jobs ->
        headers = ["ID", "Title", "Status", "Quest ID", "Bee ID"]

        rows =
          Enum.map(jobs, fn j ->
            [j.id, j.title, j.status, j.quest_id, j.bee_id || "-"]
          end)

        Format.table(headers, rows)
    end
  end

  defp dispatch([:jobs, :show], result) do
    id = result_get(result, :args, :id)

    case Hive.Jobs.get(id) do
      {:ok, job} ->
        IO.puts("ID:          #{job.id}")
        IO.puts("Title:       #{job.title}")
        IO.puts("Status:      #{job.status}")
        IO.puts("Quest ID:    #{job.quest_id}")
        IO.puts("Comb ID:     #{job.comb_id}")
        IO.puts("Bee ID:      #{job.bee_id || "-"}")
        IO.puts("Created:     #{job.inserted_at}")
        IO.puts("")

        if job.description do
          IO.puts(job.description)
        end

      {:error, :not_found} ->
        Format.error("Job not found: #{id}")
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

    case Hive.Jobs.reset(job_id) do
      {:ok, job} ->
        Format.success("Job \"#{job.title}\" reset to #{job.status} (#{job.id})")

      {:error, :not_found} ->
        Format.error("Job not found: #{job_id}")

      {:error, :invalid_transition} ->
        Format.error("Job cannot be reset from its current status.")

      {:error, reason} ->
        Format.error("Failed to reset job: #{inspect(reason)}")
    end
  end

  defp dispatch([:costs, :summary], _result) do
    summary = Hive.Costs.summary()

    IO.puts("Total cost:          $#{:erlang.float_to_binary(summary.total_cost, decimals: 4)}")
    IO.puts("Total input tokens:  #{summary.total_input_tokens}")
    IO.puts("Total output tokens: #{summary.total_output_tokens}")
    IO.puts("")

    if map_size(summary.by_model) > 0 do
      IO.puts("By model:")
      headers = ["Model", "Cost", "Input Tokens", "Output Tokens"]

      rows =
        Enum.map(summary.by_model, fn {model, data} ->
          [model, "$#{:erlang.float_to_binary(data.cost, decimals: 4)}", "#{data.input_tokens}", "#{data.output_tokens}"]
        end)

      Format.table(headers, rows)
      IO.puts("")
    end

    if map_size(summary.by_bee) > 0 do
      IO.puts("By bee:")
      headers = ["Bee ID", "Cost", "Input Tokens", "Output Tokens"]

      rows =
        Enum.map(summary.by_bee, fn {bee_id, data} ->
          [bee_id, "$#{:erlang.float_to_binary(data.cost, decimals: 4)}", "#{data.input_tokens}", "#{data.output_tokens}"]
        end)

      Format.table(headers, rows)
    end
  end

  defp dispatch([:costs, :record], result) do
    bee_id = result_get(result, :options, :bee)
    input = result_get(result, :options, :input)
    output = result_get(result, :options, :output)
    model = result_get(result, :options, :model)

    attrs = %{
      input_tokens: input,
      output_tokens: output,
      model: model
    }

    {:ok, cost} = Hive.Costs.record(bee_id, attrs)
    Format.success("Cost recorded: $#{:erlang.float_to_binary(cost.cost_usd, decimals: 6)} (#{cost.id})")
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

  defp dispatch([:handoff, :create], result) do
    bee_id = result_get(result, :options, :bee)

    case Hive.Handoff.create(bee_id) do
      {:ok, waggle} ->
        Format.success("Handoff created for #{bee_id} (waggle #{waggle.id})")

      {:error, :bee_not_found} ->
        Format.error("Bee not found: #{bee_id}")
        Format.info("Hint: use `hive bee list` to see all bees.")

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
    no_fix = result_get(result, :flags, :no_fix) || false

    case Hive.Drone.start_link(auto_fix: !no_fix) do
      {:ok, _pid} ->
        Format.success("Drone started. Running health patrols...")
        Process.sleep(:infinity)

      {:error, {:already_started, _pid}} ->
        Format.warn("Drone is already running.")

      {:error, reason} ->
        Format.error("Failed to start Drone: #{inspect(reason)}")
    end
  end

  defp dispatch([:dashboard], _result) do
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
          cell = Hive.Store.find_one(:cells, fn c -> c.bee_id == bee.id and c.status == "active" end)

          if cell do
            case Hive.Conflict.check(cell.id) do
              {:ok, :clean} -> Format.success("No conflicts detected.")
              {:error, :conflicts, files} ->
                Format.warn("Conflicts detected in #{length(files)} file(s):")
                Enum.each(files, fn f -> IO.puts("  #{f}") end)
            end
          else
            Format.info("No active cell for bee #{bee_id}")
          end

        {:error, :not_found} ->
          Format.error("Bee not found: #{bee_id}")
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
          {:ok, :pass} -> Format.success("Validation passed.")
          {:ok, :skip} -> Format.info("Validation skipped (no diff or Claude unavailable).")
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
          Format.error("Comb not found")

        is_nil(Map.get(comb, :github_owner)) || is_nil(Map.get(comb, :github_repo)) ->
          Format.error("Comb #{comb.name} has no GitHub config. Use --github-owner and --github-repo when adding.")

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
            Format.error("Comb not found: #{comb_id}")
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
            Format.error("Comb not found: #{comb_id}")
        end

      {:error, :no_comb} ->
        Format.error("No comb specified. Use --comb or set one with `hive comb use`.")
    end
  end

  defp dispatch(path, _result) do
    label = path |> Enum.map(&Atom.to_string/1) |> Enum.join(" ")
    Format.warn("\"#{label}\" is not yet implemented.")
  end

  # -- Dispatch helpers (not dispatch/2 clauses) -----------------------------

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
        Format.error("Not inside a hive workspace.")
    end
  end

  defp do_prime_bee(bee_id) do
    case Hive.Prime.prime(:bee, bee_id) do
      {:ok, markdown} -> IO.puts(markdown)
      {:error, :bee_not_found} -> Format.error("Bee not found: #{bee_id}")
      {:error, reason} -> Format.error("Prime failed: #{inspect(reason)}")
    end
  end

  defp do_quick_init(path, force?) do
    case Hive.QuickStart.quick_init(path, force: force?) do
      {:ok, summary} ->
        Format.success("Hive initialized at #{summary.hive_path}")
        IO.puts("")
        IO.puts("Welcome to The Hive!")
        IO.puts("")

        env = summary.environment
        IO.puts("Environment:")
        IO.puts("  git:    #{if env.has_git, do: "found", else: "not found"}")
        IO.puts("  claude: #{if env.has_claude, do: "found", else: "not found"}")
        IO.puts("  repos:  #{length(env.git_repos)} discovered")
        IO.puts("")

        case summary.combs_registered do
          [] ->
            Format.info("No git repos found. Add one with `hive comb add <path>`.")

          combs ->
            IO.puts("Registered combs:")

            Enum.each(combs, fn
              {:ok, name} -> Format.success("  #{name}")
              {:error, name} -> Format.error("  Failed: #{name}")
            end)
        end

      {:error, :already_initialized} ->
        Format.error("Already initialized. Use --force to reinitialize.")

      {:error, reason} ->
        Format.error("Quick init failed: #{inspect(reason)}")
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
        init: [
          name: "init",
          about: "Initialize a new Hive project in the current directory",
          args: [
            path: [
              value_name: "PATH",
              help: "Directory to initialize (defaults to current directory)",
              required: false,
              parser: :string
            ]
          ],
          flags: [
            force: [
              short: "-f",
              long: "--force",
              help: "Reinitialize even if .hive/ already exists"
            ],
            quick: [
              short: "-q",
              long: "--quick",
              help: "Quick start: auto-detect and register git repos as combs"
            ]
          ]
        ],
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
              about: "Revive a dead bee — spawn a new bee into its existing worktree to finish the work",
              args: [
                bee_id: [
                  value_name: "BEE_ID",
                  help: "ID of the dead bee whose worktree to reuse",
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
              about: "Create a new quest",
              args: [
                goal: [
                  value_name: "GOAL",
                  help: "The goal for this quest (a short name is auto-generated)",
                  required: true,
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
            delete: [
              name: "delete",
              about: "Delete a quest",
              args: [
                id: [
                  value_name: "ID",
                  help: "Quest ID to delete",
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
              options: [
                bee: [
                  short: "-b",
                  long: "--bee",
                  help: "Bee ID to record costs for",
                  parser: :string,
                  required: true
                ],
                input: [
                  long: "--input",
                  help: "Input token count",
                  parser: :integer,
                  required: true
                ],
                output: [
                  long: "--output",
                  help: "Output token count",
                  parser: :integer,
                  required: true
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
            ]
          ]
        ],
        dashboard: [
          name: "dashboard",
          about: "Open the live TUI dashboard"
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
        ]
      ]
    )
  end
end
