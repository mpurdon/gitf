defmodule GiTF.WorkflowTest do
  use ExUnit.Case, async: true

  alias GiTF.Workflow

  defp write_yaml(dir, name, body) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{name}.yaml")
    File.write!(path, body)
    path
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "workflow-test-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  describe "load/1 — happy path" do
    test "loads a minimal valid workflow", %{dir: dir} do
      path =
        write_yaml(dir, "min", """
        name: min
        phases:
          - id: a
            handler: GiTF.Phases.A
            next: end
        """)

      assert {:ok, w} = Workflow.load(path)
      assert w.name == "min"
      assert w.source_path == path
      assert [%{id: "a", next: "end"}] = w.phases
    end

    test "loads the bundled standard workflow from priv" do
      path = Path.join(:code.priv_dir(:gitf), "workflows/standard.yaml")
      assert {:ok, w} = Workflow.load(path)
      assert w.name == "standard"

      ids = Enum.map(w.phases, & &1.id)
      assert "research" in ids
      assert "implementation" in ids
      assert "scoring" in ids
    end

    test "all bundled templates pass schema validation" do
      priv_dir = Path.join(:code.priv_dir(:gitf), "workflows")

      yamls =
        File.ls!(priv_dir)
        |> Enum.filter(&String.ends_with?(&1, ".yaml"))
        |> Enum.map(&Path.join(priv_dir, &1))

      assert length(yamls) >= 3, "expected at least 3 bundled templates"

      Enum.each(yamls, fn path ->
        assert {:ok, _} = Workflow.load(path), "#{path} failed to load"
      end)
    end

    test "preserves verdict-driven branches and retry caps", %{dir: dir} do
      path =
        write_yaml(dir, "vd", """
        name: vd
        phases:
          - id: design
            handler: GiTF.Phases.Design
            next: review
          - id: review
            handler: GiTF.Phases.Review
            on_pass: end
            on_fail: design
            max_retries: 2
        """)

      assert {:ok, w} = Workflow.load(path)
      review = Enum.find(w.phases, &(&1.id == "review"))
      assert review.on_pass == "end"
      assert review.on_fail == "design"
      assert review.max_retries == 2
    end

    test "captures inject_knowledge / inject_skills / reads / produces", %{dir: dir} do
      path =
        write_yaml(dir, "deps", """
        name: deps
        phases:
          - id: research
            handler: GiTF.Phases.Research
            inject_knowledge: true
            produces: research
            next: design
          - id: design
            handler: GiTF.Phases.Design
            inject_skills: true
            reads: [research]
            next: end
        """)

      assert {:ok, w} = Workflow.load(path)
      research = Enum.find(w.phases, &(&1.id == "research"))
      design = Enum.find(w.phases, &(&1.id == "design"))

      assert research.inject_knowledge == true
      assert research.produces == "research"
      assert design.inject_skills == true
      assert design.reads == ["research"]
    end
  end

  describe "load/1 — validation errors" do
    test "rejects a workflow without a name", %{dir: dir} do
      path = write_yaml(dir, "no-name", "phases:\n  - id: a\n    next: end\n")
      assert {:error, errors} = Workflow.load(path)
      assert Enum.any?(errors, &match?({:missing_field, "name"}, &1))
    end

    test "rejects a workflow with no phases", %{dir: dir} do
      path = write_yaml(dir, "no-phases", "name: empty\nphases: []\n")
      assert {:error, errors} = Workflow.load(path)
      assert Enum.any?(errors, &match?({:missing_or_empty, "phases"}, &1))
    end

    test "rejects duplicate phase ids", %{dir: dir} do
      path =
        write_yaml(dir, "dup", """
        name: dup
        phases:
          - id: a
            next: a
          - id: a
            next: end
        """)

      assert {:error, errors} = Workflow.load(path)
      assert Enum.any?(errors, &match?({:duplicate_phase_id, "a"}, &1))
    end

    test "rejects unknown phase targets", %{dir: dir} do
      path =
        write_yaml(dir, "ghost", """
        name: ghost
        phases:
          - id: a
            next: nowhere
        """)

      assert {:error, errors} = Workflow.load(path)
      assert Enum.any?(errors, &match?({:unknown_target, "a", "next", "nowhere"}, &1))
    end

    test "rejects setting both next and on_pass/on_fail", %{dir: dir} do
      path =
        write_yaml(dir, "both", """
        name: both
        phases:
          - id: a
            next: end
            on_pass: end
            on_fail: a
        """)

      assert {:error, errors} = Workflow.load(path)
      assert Enum.any?(errors, &match?({:phase_next_and_branches, "a"}, &1))
    end

    test "rejects a phase with no advance rule", %{dir: dir} do
      path = write_yaml(dir, "no-adv", "name: no\nphases:\n  - id: a\n    handler: X\n")
      assert {:error, errors} = Workflow.load(path)
      assert Enum.any?(errors, &match?({:phase_no_advance, "a"}, &1))
    end

    test "rejects unconditional cycles", %{dir: dir} do
      path =
        write_yaml(dir, "cycle", """
        name: cycle
        phases:
          - id: a
            next: b
          - id: b
            next: a
        """)

      assert {:error, errors} = Workflow.load(path)
      assert Enum.any?(errors, &match?({:unconditional_cycle, _}, &1))
    end

    test "verdict cycles are explicitly allowed", %{dir: dir} do
      path =
        write_yaml(dir, "vcycle", """
        name: vcycle
        phases:
          - id: impl
            on_pass: validate
            on_fail: impl
            max_retries: 3
          - id: validate
            on_pass: end
            on_fail: impl
            max_retries: 3
        """)

      assert {:ok, _} = Workflow.load(path)
    end

    test "rejects reads referencing artifacts not produced earlier", %{dir: dir} do
      path =
        write_yaml(dir, "reads", """
        name: reads
        phases:
          - id: validation
            handler: GiTF.Phases.Validation
            reads: [implementation]
            next: end
          - id: implementation
            handler: GiTF.Phases.Implementation
            produces: implementation
            next: validation
        """)

      assert {:error, errors} = Workflow.load(path)
      assert Enum.any?(errors, &match?({:missing_artifact, "validation", "implementation"}, &1))
    end

    test "rejects bad model_tier values", %{dir: dir} do
      path =
        write_yaml(dir, "tier", """
        name: tier
        phases:
          - id: a
            model_tier: enormous
            next: end
        """)

      assert {:error, errors} = Workflow.load(path)
      assert Enum.any?(errors, &match?({:phase_bad_model_tier, "a", _}, &1))
    end
  end

  describe "next_phase/3" do
    setup do
      yaml = """
      name: t
      phases:
        - id: design
          next: review
        - id: review
          on_pass: planning
          on_fail: design
          max_retries: 2
        - id: planning
          next: end
      """

      tmp = Path.join(System.tmp_dir!(), "workflow-next-#{:erlang.unique_integer([:positive])}.yaml")
      File.write!(tmp, yaml)
      on_exit(fn -> File.rm!(tmp) end)
      {:ok, w} = Workflow.load(tmp)
      %{workflow: w}
    end

    test "returns next on unconditional advance", %{workflow: w} do
      assert {:ok, "review"} = Workflow.next_phase(w, "design", :advance)
    end

    test "uses on_pass for :pass verdict", %{workflow: w} do
      assert {:ok, "planning"} = Workflow.next_phase(w, "review", :pass)
    end

    test "uses on_fail for :fail verdict", %{workflow: w} do
      assert {:ok, "design"} = Workflow.next_phase(w, "review", :fail)
    end

    test "returns :end on the last phase", %{workflow: w} do
      assert {:ok, :end} = Workflow.next_phase(w, "planning", :advance)
    end

    test "errors for unknown phase", %{workflow: w} do
      assert {:error, {:unknown_phase, "nope"}} = Workflow.next_phase(w, "nope", :advance)
    end

    test "errors when verdict has no branch", %{workflow: w} do
      # `review` is verdict-driven (no `next`); :advance has no branch to follow.
      assert {:error, {:no_unconditional_next, "review"}} =
               Workflow.next_phase(w, "review", :advance)
    end
  end

  describe "entry_phase/1" do
    test "returns the first phase", %{dir: dir} do
      path = write_yaml(dir, "ep", "name: ep\nphases:\n  - id: first\n    next: end\n")
      {:ok, w} = Workflow.load(path)
      assert {:ok, %{id: "first"}} = Workflow.entry_phase(w)
    end
  end

  describe "write/2 — round-trip" do
    test "serialize → parse round-trips field values", %{dir: dir} do
      original =
        write_yaml(dir, "rt", """
        name: rt
        description: A round-trip test
        phases:
          - id: a
            handler: GiTF.Phases.Default
            model_tier: opus
            timeout_minutes: 45
            inject_knowledge: true
            inject_skills: true
            reads: []
            produces: a
            next: b
          - id: b
            handler: GiTF.Phases.Default
            reads: [a]
            on_pass: end
            on_fail: a
            max_retries: 2
        """)

      {:ok, loaded} = Workflow.load(original)

      # Round-trip via serialize/load so the test stays independent of
      # the vault-path restriction enforced by Workflow.write/2.
      target = Path.join(dir, "rt-out.yaml")
      File.write!(target, Workflow.serialize(loaded))
      {:ok, reloaded} = Workflow.load(target)

      assert reloaded.name == loaded.name
      assert length(reloaded.phases) == length(loaded.phases)

      [a1, b1] = loaded.phases
      [a2, b2] = reloaded.phases

      assert a2.id == a1.id
      assert a2.handler == a1.handler
      assert a2.model_tier == a1.model_tier
      assert a2.timeout_minutes == a1.timeout_minutes
      assert a2.inject_knowledge == a1.inject_knowledge
      assert a2.next == a1.next
      assert b2.on_pass == b1.on_pass
      assert b2.on_fail == b1.on_fail
      assert b2.max_retries == b1.max_retries
      assert b2.reads == b1.reads
    end

    test "errors when no source path", %{dir: _dir} do
      w = %Workflow{name: "x", phases: []}
      assert {:error, :no_target_path} = Workflow.write(w)
    end

    test "rejects writes outside the vault Workflows tree", %{dir: dir} do
      w = %Workflow{name: "outside", phases: [%Workflow.Phase{id: "a", next: "end"}]}

      # Path is under the test temp dir which is not the vault — refuse.
      assert {:error, {:workflow_path_outside_vault, _}} =
               Workflow.write(w, Path.join(dir, "outside.yaml"))
    end

    test "rejects names that traverse out of the vault" do
      assert {:error, {:invalid_workflow_name, "../../etc/passwd"}} =
               Workflow.resolve("../../etc/passwd")

      assert {:error, {:invalid_workflow_name, "/etc/passwd"}} =
               Workflow.resolve("/etc/passwd")

      assert {:error, {:invalid_workflow_name, "evil/../escape"}} =
               Workflow.resolve("evil/../escape")
    end
  end
end
