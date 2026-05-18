defmodule GiTF.Workflow.ConditionalNextTest do
  use GiTF.StoreCase

  alias GiTF.Workflow
  alias GiTF.Workflow.{Advancer, Phase, Schema}

  # A triage-shaped workflow with data-dependent routing.
  defp triage_phase do
    %Phase{
      id: "triage",
      next: [
        Phase.transition!("artifact.bug_reproducible == false", "end"),
        Phase.transition!("artifact.skip_flags.research == true", "requirements"),
        {:else, "research"}
      ]
    }
  end

  defp workflow do
    %Workflow{
      name: "cond",
      phases: [
        triage_phase(),
        %Phase{id: "research", next: "requirements"},
        %Phase{id: "requirements", next: "end"}
      ]
    }
  end

  defp insert_mission!(attrs) do
    {:ok, m} =
      GiTF.Archive.insert(
        :missions,
        Map.merge(%{name: "c", goal: "x", status: "active", sector_id: "fe", artifacts: %{}}, attrs)
      )

    m
  end

  describe "Workflow.next_phase/4 with conditional next" do
    test "first matching rule wins" do
      w = workflow()
      ctx = fn art -> %{artifact: art, mission: %{}} end

      assert {:ok, :end} = Workflow.next_phase(w, "triage", :advance, ctx.(%{"bug_reproducible" => false}))

      assert {:ok, "requirements"} =
               Workflow.next_phase(w, "triage", :advance, ctx.(%{"skip_flags" => %{"research" => true}}))

      assert {:ok, "research"} = Workflow.next_phase(w, "triage", :advance, ctx.(%{}))
    end

    test "falls through to :else when an expression errors at runtime is impossible — bad data just doesn't match" do
      w = workflow()
      # No artifact at all → conditions are nil-comparisons → none match → :else.
      assert {:ok, "research"} = Workflow.next_phase(w, "triage", :advance, %{artifact: nil, mission: %{}})
    end

    test "string next still works and ignores ctx" do
      w = workflow()
      assert {:ok, "requirements"} = Workflow.next_phase(w, "research", :advance, %{})
    end
  end

  describe "Advancer.decide/2 with a conditional-next phase" do
    test "routes to the rule whose expression holds against the phase artifact" do
      m =
        insert_mission!(%{
          current_phase: "triage",
          artifacts: %{"triage" => %{"skip_flags" => %{"research" => true}}}
        })

      assert {:dispatch, "requirements"} = Advancer.decide(m, workflow())
    end

    test "short-circuits to :end when the artifact says so" do
      m = insert_mission!(%{current_phase: "triage", artifacts: %{"triage" => %{"bug_reproducible" => false}}})
      assert :complete = Advancer.decide(m, workflow())
    end

    test "default route when no rule matches" do
      m = insert_mission!(%{current_phase: "triage", artifacts: %{"triage" => %{"complexity" => "complex"}}})
      assert {:dispatch, "research"} = Advancer.decide(m, workflow())
    end

    test "waits while the triage artifact is missing" do
      m = insert_mission!(%{current_phase: "triage", artifacts: %{}})
      assert {:wait, "triage"} = Advancer.decide(m, workflow())
    end
  end

  describe "Schema validation of conditional next" do
    defp raw(next_value) do
      %{
        "name" => "w",
        "phases" => [
          %{"id" => "triage", "next" => next_value},
          %{"id" => "research", "next" => "end"}
        ]
      }
    end

    test "accepts a well-formed conditional next" do
      assert {:ok, %Workflow{phases: [triage | _]}} =
               Schema.validate(
                 raw([
                   %{"when" => "artifact.skip_flags.research == true", "then" => "research"},
                   %{"else" => "research"}
                 ])
               )

      assert [{"artifact.skip_flags.research == true", _ast, "research"}, {:else, "research"}] = triage.next
    end

    test "rejects an unknown target inside a rule" do
      assert {:error, errors} =
               Schema.validate(
                 raw([%{"when" => "artifact.x == true", "then" => "nowhere"}, %{"else" => "research"}])
               )

      assert Enum.any?(errors, &match?({:unknown_target, "triage", "next", "nowhere"}, &1))
    end

    test "rejects a bad when: expression" do
      assert {:error, errors} =
               Schema.validate(raw([%{"when" => "File.read!(\"x\")", "then" => "research"}, %{"else" => "research"}]))

      assert Enum.any?(errors, &match?({:bad_transition, "triage", "next", {:bad_when_expr, _, _}}, &1))
    end

    test "requires exactly one else, last" do
      assert {:error, e1} = Schema.validate(raw([%{"when" => "artifact.x == true", "then" => "research"}]))
      assert Enum.any?(e1, &match?({:conditional_branch_needs_one_else, "triage", "next"}, &1))

      assert {:error, e2} =
               Schema.validate(
                 raw([%{"else" => "research"}, %{"when" => "artifact.x == true", "then" => "research"}])
               )

      assert Enum.any?(e2, &match?({:conditional_branch_else_not_last, "triage", "next"}, &1))
    end

    test "rejects next AND on_pass/on_fail together" do
      assert {:error, errors} =
               Schema.validate(%{
                 "name" => "w",
                 "phases" => [
                   %{
                     "id" => "triage",
                     "next" => [%{"else" => "research"}],
                     "on_pass" => "research",
                     "on_fail" => "research"
                   },
                   %{"id" => "research", "next" => "end"}
                 ]
               })

      assert Enum.any?(errors, &match?({:phase_next_and_branches, "triage"}, &1))
    end
  end

  describe "conditional on_pass / on_fail" do
    test "Workflow.next_phase resolves a conditional on_pass" do
      w = %Workflow{
        name: "v",
        phases: [
          %Phase{
            id: "validation",
            on_pass: [
              Phase.transition!("mission.requires_approval == true", "awaiting_approval"),
              {:else, "simplify"}
            ],
            on_fail: "implementation"
          },
          %Phase{id: "implementation", next: "validation"},
          %Phase{id: "awaiting_approval", next: "end"},
          %Phase{id: "simplify", next: "end"}
        ]
      }

      assert {:ok, "awaiting_approval"} =
               Workflow.next_phase(w, "validation", :pass, %{mission: %{requires_approval: true}})

      assert {:ok, "simplify"} =
               Workflow.next_phase(w, "validation", :pass, %{mission: %{requires_approval: false}})
    end

    test "schema accepts and round-trips a conditional on_pass" do
      raw = %{
        "name" => "v",
        "phases" => [
          %{
            "id" => "validation",
            "on_pass" => [
              %{"when" => "mission.requires_approval == true", "then" => "awaiting_approval"},
              %{"else" => "simplify"}
            ],
            "on_fail" => "implementation",
            "max_retries" => 3
          },
          %{"id" => "implementation", "next" => "validation"},
          %{"id" => "awaiting_approval", "next" => "end"},
          %{"id" => "simplify", "next" => "end"}
        ]
      }

      assert {:ok, w} = Schema.validate(raw)
      validation_phase = Enum.find(w.phases, &(&1.id == "validation"))

      assert [
               {"mission.requires_approval == true", _ast, "awaiting_approval"},
               {:else, "simplify"}
             ] = validation_phase.on_pass

      # round-trip through serialize. The compiled AST round-trips because
      # the schema re-compiles the source on the way back in.
      yaml = Workflow.serialize(w)
      {:ok, parsed} = YamlElixir.read_from_string(yaml)
      assert {:ok, w2} = Schema.validate(parsed)
      validation2 = Enum.find(w2.phases, &(&1.id == "validation"))
      # Compare source + target; the AST is structurally equal but might
      # differ in metadata between compiles.
      assert sources_and_targets(validation2.on_pass) ==
               sources_and_targets(validation_phase.on_pass)
    end
  end

  describe "YAML round-trip" do
    test "serialize → parse preserves conditional next" do
      yaml = Workflow.serialize(workflow())
      {:ok, parsed} = YamlElixir.read_from_string(yaml)
      assert {:ok, w2} = Schema.validate(parsed)
      [triage2 | _] = w2.phases

      assert sources_and_targets(triage2.next) == [
               {"artifact.bug_reproducible == false", "end"},
               {"artifact.skip_flags.research == true", "requirements"},
               {:else, "research"}
             ]
    end
  end

  # Strip the cached AST so we can compare source + target across
  # round-trips without depending on AST metadata equality.
  defp sources_and_targets(transitions) do
    Enum.map(transitions, fn
      {:else, target} -> {:else, target}
      {source, _ast, target} -> {source, target}
    end)
  end
end
