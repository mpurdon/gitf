defmodule GiTF.MCPServer.ApprovalToolsTest do
  @moduledoc """
  A mission held at `awaiting_approval` was answerable only by reading the
  raw validation artifact off the box — the operator hit exactly that and
  fell back to SSM console probes, which `docs/MCP.md` calls a coverage
  bug rather than a workaround.

  The triage in these responses comes from `GiTF.Approval.Triage`, the
  same module the Catwalk's approval panel renders, so the two surfaces
  cannot drift into disagreeing about what failed.
  """
  use GiTF.StoreCase

  alias GiTF.Approval.Triage
  alias GiTF.MCPServer.{Handlers, Tools}
  alias GiTF.{Archive, Missions, Override}

  defp mission!(artifacts, fields \\ %{}) do
    {:ok, m} =
      Archive.insert(
        :missions,
        Map.merge(
          %{
            name: "approval-mcp",
            goal: "ship the thing",
            status: "active",
            sector_id: "no-such-sector",
            current_phase: "awaiting_approval",
            artifacts: artifacts,
            ops: []
          },
          fields
        )
      )

    m
  end

  defp request!(mission_id, fields \\ %{}) do
    {:ok, r} =
      Archive.insert(
        :approval_requests,
        Map.merge(
          %{
            mission_id: mission_id,
            quest_name: "approval-mcp",
            goal: "ship the thing",
            risk_levels: [:normal],
            files_touched: ["lib/a.ex"],
            job_count: 1,
            status: "pending",
            requested_at: DateTime.utc_now()
          },
          fields
        )
      )

    r
  end

  # A clean pass with one advisory gap — the msn-ac0539 shape.
  defp passing_mission do
    m =
      mission!(%{
        "validation" => %{
          "overall_verdict" => "pass",
          "requires_approval" => true,
          "summary" => "all requirements verified",
          "requirements_met" => [
            %{"req_id" => "FR-1", "met" => true, "evidence" => "covered"},
            %{
              "req_id" => "FR-2",
              "met" => true,
              "rebuttal" => "client.ex:44 now retries, which the earlier round found missing"
            }
          ],
          "gaps" => ["the new timeout setting is not surfaced anywhere in the UI"]
        }
      })

    request!(m.id)
    m
  end

  # A pass verdict carrying a genuinely unmet requirement.
  defp failing_mission do
    m =
      mission!(%{
        "validation" => %{
          "overall_verdict" => "pass",
          "requirements_met" => [
            %{"req_id" => "FR-1", "met" => true},
            %{"req_id" => "FR-5", "met" => false, "evidence" => "no retry on 5xx responses"}
          ]
        }
      })

    request!(m.id)
    m
  end

  defp decode(text), do: Jason.decode!(text)

  describe "tool registry" do
    test "all four approval tools are registered with the right contract" do
      by_name = Map.new(Tools.all(), &{&1.name, &1})

      for name <- ~w(show_approval approve_mission reject_mission set_approval_timeout) do
        assert Map.has_key?(by_name, name), "expected #{name} to be registered"
      end

      assert Map.get(by_name["show_approval"].inputSchema, :required) == ["id"]

      # Every write is confirm-gated, like kill_mission and resume_mission.
      for name <- ~w(approve_mission reject_mission set_approval_timeout) do
        required = Map.get(by_name[name].inputSchema, :required) || []
        assert "confirm" in required, "#{name} must require confirm"
        assert by_name[name].description =~ "[WRITE]"
      end

      assert "reason" in Map.get(by_name["reject_mission"].inputSchema, :required)

      # The two facts an operator gets wrong: who the actor is, and that a
      # rejection is not a feedback loop.
      assert by_name["approve_mission"].description =~ "mcp_operator"
      assert by_name["reject_mission"].description =~ "NO ghost consumes it"
    end
  end

  describe "show_approval" do
    test "returns the triage groups, not a raw artifact" do
      m = passing_mission()

      assert {:ok, text} = Handlers.call("show_approval", %{"id" => m.id})
      body = decode(text)

      assert body["mission_id"] == m.id
      assert body["approval_status"] == "pending"
      assert body["counts"] == %{"fails" => 0, "concerns" => 1, "oks" => 2}
      assert body["tally"] == "0 fails · 1 concern · 2 ok"

      assert [gap] = body["concerns"]
      assert gap["status"] == "concerns"
      assert gap["kind"] == "gap"
      assert gap["title"] =~ "not surfaced anywhere in the UI"

      # A rebuttal is the argument that overturned an earlier verdict — it
      # has to survive to the operator, not just to the artifact.
      rebutted = Enum.find(body["oks"], &(&1["kind"] == "contested_rebutted"))
      assert rebutted["rebuttal"] =~ "client.ex:44"
    end

    test "the MCP and the Catwalk derive from the same module" do
      m = passing_mission()
      {:ok, mission} = Missions.get(m.id)

      {:ok, text} = Handlers.call("show_approval", %{"id" => m.id})
      body = decode(text)

      triage = Triage.build(mission)

      assert body["tally"] == Triage.tally(triage)
      assert body["counts"]["fails"] == length(triage.fails)
      assert body["counts"]["concerns"] == length(triage.concerns)
      assert body["counts"]["oks"] == length(triage.oks)
    end

    test "carries the request and the timeout state" do
      m = passing_mission()

      {:ok, text} = Handlers.call("show_approval", %{"id" => m.id})
      body = decode(text)

      assert body["request"]["status"] == "pending"
      assert body["request"]["job_count"] == 1
      assert body["request"]["requested_at"]

      timeout = body["timeout"]
      assert is_number(timeout["hours_configured"])
      assert is_number(timeout["hours_elapsed"])
      assert timeout["max_risk"] == "normal"
      # Only critical-risk work is barred from auto-approving.
      assert timeout["auto_approve_possible"] == true
    end

    test "a critical-risk mission says auto-approve is impossible" do
      m =
        mission!(%{"validation" => %{"overall_verdict" => "pass"}}, %{
          ops: [%{id: "op-1", risk_level: :critical, status: "done"}]
        })

      request!(m.id)

      {:ok, text} = Handlers.call("show_approval", %{"id" => m.id})
      timeout = decode(text)["timeout"]

      assert timeout["max_risk"] == "critical"
      assert timeout["auto_approve_possible"] == false
      assert timeout["note"] =~ "auto-REJECTS"
    end

    test "answers for an already-decided approval instead of erroring" do
      m = passing_mission()
      {:ok, _} = Override.approve(m.id, %{approved_by: "someone"})

      {:ok, text} = Handlers.call("show_approval", %{"id" => m.id})
      assert decode(text)["approval_status"] == "approved"
    end

    test "names the mission when it does not exist" do
      assert {:error, msg} = Handlers.call("show_approval", %{"id" => "msn-nope"})
      assert msg =~ "msn-nope"
    end

    test "requires an id" do
      assert {:error, msg} = Handlers.call("show_approval", %{})
      assert msg =~ "id"
    end
  end

  describe "approve_mission" do
    test "refuses without confirm" do
      m = passing_mission()

      assert {:error, msg} = Handlers.call("approve_mission", %{"id" => m.id})
      assert msg =~ "confirm"
      assert Override.approval_status(m.id) == :pending
    end

    test "approves a pending request and records the surface as the actor" do
      m = passing_mission()

      assert {:ok, text} =
               Handlers.call("approve_mission", %{
                 "id" => m.id,
                 "confirm" => true,
                 "notes" => "read the gap, shipping anyway"
               })

      body = decode(text)
      assert body["decided"] == true
      assert body["approval_status"] == "approved"
      assert body["approved_by"] == "mcp_operator"
      assert body["notes"] == "read the gap, shipping anyway"

      assert Override.approval_status(m.id) == :approved
      assert Missions.get_artifact(m.id, "approval")["approved_by"] == "mcp_operator"
    end

    test "a clean approval carries no warning" do
      m = passing_mission()

      {:ok, text} = Handlers.call("approve_mission", %{"id" => m.id, "confirm" => true})
      body = decode(text)

      refute Map.has_key?(body, "warning")
      assert body["tally"] == "0 fails · 1 concern · 2 ok"
    end

    test "approving over failing checks still works but names them" do
      m = failing_mission()

      assert {:ok, text} = Handlers.call("approve_mission", %{"id" => m.id, "confirm" => true})
      body = decode(text)

      # The operator outranks the machine — but does not get to not-see it.
      assert body["approval_status"] == "approved"
      assert body["warning"] =~ "APPROVED OVER 1 FAILING CHECK"
      assert body["warning"] =~ "FR-5 NOT met"
      assert body["approved_over_fails"] == ["FR-5 NOT met"]

      assert Override.approval_status(m.id) == :approved
    end

    test "refuses a mission that is not pending, returning the status" do
      m = passing_mission()
      {:ok, _} = Override.reject(m.id, "no", %{rejected_by: "someone"})

      assert {:ok, text} = Handlers.call("approve_mission", %{"id" => m.id, "confirm" => true})
      body = decode(text)

      assert body["decided"] == false
      assert body["approval_status"] == "rejected"
      assert body["note"] =~ "Already rejected"
    end

    test "names the mission when it does not exist" do
      assert {:error, msg} =
               Handlers.call("approve_mission", %{"id" => "msn-nope", "confirm" => true})

      assert msg =~ "msn-nope"
    end
  end

  describe "reject_mission" do
    test "requires a reason" do
      m = passing_mission()

      assert {:error, msg} = Handlers.call("reject_mission", %{"id" => m.id, "confirm" => true})
      assert msg =~ "reason"
      assert Override.approval_status(m.id) == :pending
    end

    test "a blank reason is no reason" do
      m = passing_mission()

      assert {:error, msg} =
               Handlers.call("reject_mission", %{
                 "id" => m.id,
                 "reason" => "   ",
                 "confirm" => true
               })

      assert msg =~ "blank"
      assert Override.approval_status(m.id) == :pending
    end

    test "refuses without confirm" do
      m = passing_mission()

      assert {:error, msg} =
               Handlers.call("reject_mission", %{"id" => m.id, "reason" => "not ready"})

      assert msg =~ "confirm"
    end

    test "rejects and states plainly what happens next" do
      m = passing_mission()

      assert {:ok, text} =
               Handlers.call("reject_mission", %{
                 "id" => m.id,
                 "reason" => "the gap is behavioral, not cosmetic",
                 "confirm" => true
               })

      body = decode(text)
      assert body["approval_status"] == "rejected"
      assert body["rejected_by"] == "mcp_operator"
      assert body["reason"] == "the gap is behavioral, not cosmetic"

      # The three things an operator gets wrong about a rejection.
      assert body["note"] =~ "terminal-fails"
      assert body["note"] =~ "archive/#{m.id}"
      assert body["note"] =~ "NO ghost consumes it"

      assert Override.approval_status(m.id) == :rejected
      assert Missions.get_artifact(m.id, "approval")["approved"] == false
    end

    test "refuses a mission that is not pending, returning the status" do
      m = passing_mission()
      {:ok, _} = Override.approve(m.id, %{approved_by: "someone"})

      assert {:ok, text} =
               Handlers.call("reject_mission", %{
                 "id" => m.id,
                 "reason" => "too late",
                 "confirm" => true
               })

      assert decode(text)["approval_status"] == "approved"
      assert decode(text)["decided"] == false
    end
  end

  describe "set_approval_timeout" do
    setup do
      # The write lands in a real config file. Redirect the gitf root at a
      # temp dir so a test can never clobber the operator's own config.
      tmp =
        Path.join(System.tmp_dir!(), "gitf_approval_cfg_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(tmp, ".gitf"))
      # `GiTF.gitf_dir/0` only accepts a root whose `.gitf/config.toml`
      # already EXISTS. Without this seed the root does not resolve, and
      # the tool refuses — which is the point of the refusal, but not what
      # these tests are exercising.
      File.write!(Path.join([tmp, ".gitf", "config.toml"]), "")

      prior = System.get_env("GITF_PATH")
      System.put_env("GITF_PATH", tmp)

      on_exit(fn ->
        if prior, do: System.put_env("GITF_PATH", prior), else: System.delete_env("GITF_PATH")
        File.rm_rf!(tmp)
      end)

      %{tmp: tmp}
    end

    test "refuses without confirm" do
      assert {:error, msg} = Handlers.call("set_approval_timeout", %{"hours" => 4})
      assert msg =~ "confirm"
    end

    test "refuses a timeout that would auto-approve on request" do
      assert {:error, msg} =
               Handlers.call("set_approval_timeout", %{"hours" => 0, "confirm" => true})

      assert msg =~ "greater than 0"
    end

    test "refuses a fat-fingered timeout" do
      assert {:error, msg} =
               Handlers.call("set_approval_timeout", %{"hours" => 100_000, "confirm" => true})

      assert msg =~ "at most 720"
    end

    test "refuses a non-number" do
      assert {:error, msg} =
               Handlers.call("set_approval_timeout", %{"hours" => "four", "confirm" => true})

      assert msg =~ "must be a number"
    end

    test "persists to the config file the factory reads", %{tmp: tmp} do
      previous = GiTF.Approval.timeout_hours()

      assert {:ok, text} =
               Handlers.call("set_approval_timeout", %{"hours" => 6, "confirm" => true})

      body = decode(text)
      assert body["setting"] == "approvals.timeout_hours"
      assert body["previous_hours"] == previous
      assert body["note"] =~ "AWAKE time"

      # Durability: the value is on disk, not only in persistent_term, so
      # it survives the restart that a Provider.put would not.
      written = File.read!(Path.join([tmp, ".gitf", "config.toml"]))
      assert written =~ "[approvals]"
      assert written =~ "timeout_hours = 6"
    end

    test "the receipt re-reads the effective value rather than echoing the input" do
      assert {:ok, text} =
               Handlers.call("set_approval_timeout", %{"hours" => 6, "confirm" => true})

      # An env var outranks the config file, so the only honest receipt is
      # what the factory would actually read back.
      assert decode(text)["timeout_hours"] == GiTF.Approval.timeout_hours()
    end

    test "merges into an existing section instead of replacing the file", %{tmp: tmp} do
      path = Path.join([tmp, ".gitf", "config.toml"])

      File.write!(
        path,
        "[major]\nmax_ghosts = 9\n\n[approvals]\ncritical_escalation_hours = 48\n"
      )

      assert {:ok, _} = Handlers.call("set_approval_timeout", %{"hours" => 6, "confirm" => true})

      written = File.read!(path)
      assert written =~ "timeout_hours = 6"
      assert written =~ "critical_escalation_hours = 48"
      assert written =~ "max_ghosts = 9"
    end

    test "refuses to overwrite a config file it cannot parse", %{tmp: tmp} do
      path = Path.join([tmp, ".gitf", "config.toml"])
      File.write!(path, "this is not = = valid toml [[[")

      assert {:error, msg} =
               Handlers.call("set_approval_timeout", %{"hours" => 6, "confirm" => true})

      assert msg =~ "does not parse"

      # write_config/2 serialises the WHOLE map, so treating an unreadable
      # file as empty would have replaced the operator's entire config.
      assert File.read!(path) == "this is not = = valid toml [[["
    end

    test "refuses when no gitf root resolves rather than guessing at a file", %{tmp: tmp} do
      # Quietly rewriting ~/.config/gitf/config.toml because a workspace
      # could not be found is the kind of surprise a write tool must not
      # have — this test exists because an earlier draft did exactly that.
      System.put_env("GITF_PATH", Path.join(tmp, "nowhere"))

      assert {:error, msg} =
               Handlers.call("set_approval_timeout", %{"hours" => 6, "confirm" => true})

      assert msg =~ "No gitf root"
      refute File.exists?(Path.join([tmp, "nowhere", ".gitf", "config.toml"]))
    end

    test "the effective value the receipt reports is read from the config" do
      prior = GiTF.Config.Provider.get([:approvals])
      on_exit(fn -> GiTF.Config.Provider.put([:approvals], prior) end)

      # Whole-section put: Provider.put/2 is put_in/3 underneath and raises
      # on a missing intermediate key.
      GiTF.Config.Provider.put([:approvals], %{timeout_hours: 9})

      assert GiTF.Approval.timeout_hours() == 9
    end
  end

  describe "serialize_mission" do
    test "show_mission carries both requirement registers" do
      m =
        mission!(%{}, %{
          contested_requirements: [%{"req_id" => "FR-5", "reason" => "no retry on 5xx"}],
          accepted_requirements: ["FR-1", "FR-2"]
        })

      assert {:ok, text} = Handlers.call("show_mission", %{"id" => m.id})
      body = decode(text)

      # Reading these needed a gitf-console probe over SSM — the register
      # is what the next round's validator is made to answer.
      assert body["contested_requirements"] == [
               %{"req_id" => "FR-5", "reason" => "no retry on 5xx"}
             ]

      assert body["accepted_requirements"] == ["FR-1", "FR-2"]
    end

    test "a mission with neither register reports empty lists, not null" do
      m = mission!(%{})

      {:ok, text} = Handlers.call("show_mission", %{"id" => m.id})
      body = decode(text)

      assert body["contested_requirements"] == []
      assert body["accepted_requirements"] == []
    end
  end
end
