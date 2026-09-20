defmodule GiTF.Quality.UnavailableIsNotCleanTest do
  @moduledoc """
  An analyser that never ran must never read as a pass.

  `[]` findings score 100, so any scanner that is missing, crashed, timed out,
  or simply has no implementation for the language will produce a perfect
  score unless something downstream refuses it. The 2026-08-28 BEAM audit
  found this in the dependency scanner and it was fixed there; the static path
  kept the same shape and was missed in three places at once — the analyser
  claimed `available: true` for unknown languages, the audit consumer ignored
  the flag, and the composite averaged the fabricated score in regardless.

  These tests fail if any of the three regresses.
  """
  use GiTF.StoreCase

  alias GiTF.Archive
  alias GiTF.Quality
  alias GiTF.Quality.StaticAnalysis

  describe "StaticAnalysis.analyze/2 — the analyser tells the truth" do
    test "a language with no configured analyser reports unavailable" do
      # The score is 100 because nothing looked. `available: false` is the
      # only thing standing between that and a clean bill of health.
      assert {:ok, result} = StaticAnalysis.analyze(".", :cobol)
      assert result.available == false
      assert result.tool == "none"
    end

    test "every unconfigured language is unavailable, not clean" do
      for language <- [:cobol, :haskell, :zig, :unknown, nil] do
        assert {:ok, %{available: false}} = StaticAnalysis.analyze(".", language),
               "#{inspect(language)} claimed an analyser ran"
      end
    end

    test "a configured language whose tool is missing is also unavailable" do
      # No mix project at this path, so credo cannot run. It must say so
      # rather than report a clean Elixir codebase.
      assert {:ok, result} =
               StaticAnalysis.analyze("/nonexistent-path-#{:rand.uniform(99999)}", :elixir)

      assert result.available == false
    end
  end

  describe "calculate_composite_score/1 — unmeasured is excluded, not averaged" do
    defp report(op_id, type, score, available) do
      {:ok, r} =
        Archive.insert(:quality_reports, %{
          id: GiTF.ID.generate(:qr),
          op_id: op_id,
          analysis_type: type,
          score: score,
          issues: [],
          tool: "test",
          tool_available: available,
          recommendations: [],
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })

      r
    end

    test "a scanner that never ran does not lift the composite" do
      op = "op-#{:rand.uniform(999_999)}"
      # Static genuinely measured and poor; security never ran (score 100).
      report(op, "static", 20, true)
      report(op, "security", 100, false)

      # Were the unavailable security report averaged in, this would be
      # round(20 * 0.6 + 100 * 0.4) = 52 — a passing-looking number invented
      # by a scanner that did nothing.
      assert Quality.calculate_composite_score(op) == 20
    end

    test "an op where nothing ran is not measured rather than perfect" do
      op = "op-#{:rand.uniform(999_999)}"
      report(op, "static", 100, false)
      report(op, "security", 100, false)

      refute Quality.calculate_composite_score(op) == 100
      assert Quality.calculate_composite_score(op) == nil
    end

    test "reports that did run are still weighted as before" do
      op = "op-#{:rand.uniform(999_999)}"
      report(op, "static", 80, true)
      report(op, "security", 60, true)

      assert Quality.calculate_composite_score(op) == round(80 * 0.6 + 60 * 0.4)
    end

    test "a report with no tool_available key is assumed to have run" do
      # Backwards compatibility: reports written before the flag existed.
      op = "op-#{:rand.uniform(999_999)}"

      {:ok, _} =
        Archive.insert(:quality_reports, %{
          id: GiTF.ID.generate(:qr),
          op_id: op,
          analysis_type: "static",
          score: 75,
          issues: [],
          tool: "legacy",
          recommendations: [],
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        })

      assert Quality.calculate_composite_score(op) == 75
    end
  end

  describe "every analyser return path declares availability" do
    test "no parse path can omit the flag and inherit the default-true" do
      # Quality.analyze_static/3 reads `Map.get(result, :available, true)`, so a
      # return path that forgets the key is silently a pass. This is how the
      # real bug shipped: the JSON-decode-failure branches — the exact path a
      # missing or failing credo/eslint/pylint takes — had no flag at all.
      source = File.read!("lib/gitf/quality/static_analysis.ex")

      returns =
        Regex.scan(~r/\{:ok, %\{issues:.*?\}\}/s, source)
        |> Enum.map(&List.first/1)

      assert returns != [], "expected to find analyser return shapes"

      for r <- returns do
        assert r =~ "available:",
               "an analyser return path omits :available and will default to a pass:\n#{r}"
      end
    end
  end

  describe "Quality.analyze_static/3 — the flag survives into the report" do
    test "an unconfigured language is recorded as tool_available: false" do
      op = "op-#{:rand.uniform(999_999)}"

      assert {:ok, report} = Quality.analyze_static(op, ".", :cobol)
      assert report.tool_available == false
    end
  end
end
