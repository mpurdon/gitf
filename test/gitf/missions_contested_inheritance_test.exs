defmodule GiTF.MissionsContestedInheritanceTest do
  @moduledoc """
  The half of the msn-978954 failure that a per-mission gate cannot
  reach. The requirement FR-5 was judged unmet by the PARENT run
  (msn-398fa4); the child was a resume, and a resume starts with an empty
  `contested_requirements`. Its validator therefore met a requirement its
  own record had never seen rejected, on code neither run had changed.

  So contestation is inherited, and the inheritance rule is deliberately
  asymmetric: a bare `met: true` anywhere in the lineage does NOT clear
  it — that IS the false pass. Only a flip carrying a real rebuttal
  clears it. A requirement an ancestor genuinely fixed therefore arrives
  contested in the child and costs its validator one honest sentence
  citing the fix. That is the price, and it is the cheap side of the
  trade.
  """
  use GiTF.StoreCase

  alias GiTF.Archive
  alias GiTF.Missions

  @rebuttal "the retry loop landed in client.ex on the parent's last fix round, which is what FR-5 asked for"

  defp mission!(fields) do
    {:ok, m} =
      Archive.insert(
        :missions,
        Map.merge(%{name: "lineage", goal: "x", status: "failed", ops: []}, fields)
      )

    m
  end

  defp validation(entries), do: %{"validation" => %{"requirements_met" => entries}}

  defp unmet(id, evidence), do: %{"req_id" => id, "met" => false, "evidence" => evidence}

  describe "inherited_contested/1" do
    test "an ancestor's UNMET verdict survives a descendant's bare met:true" do
      a = mission!(%{artifacts: validation([unmet("FR-5", "no retry on 5xx responses")])})

      b =
        mission!(%{
          resumed_from: a.id,
          artifacts:
            validation([
              %{"req_id" => "FR-5", "met" => true, "evidence" => "looks implemented to me"}
            ])
        })

      # This is the exact msn-978954 shape, and the answer must be that
      # FR-5 is still contested — with the reason the round that actually
      # examined it gave, since B never articulated an unmet verdict of
      # its own.
      assert Missions.inherited_contested(b) == [
               %{"req_id" => "FR-5", "reason" => "no retry on 5xx responses"}
             ]
    end

    test "an argued flip anywhere in the lineage clears it" do
      a = mission!(%{artifacts: validation([unmet("FR-5", "no retry on 5xx responses")])})

      b =
        mission!(%{
          resumed_from: a.id,
          artifacts: validation([%{"req_id" => "FR-5", "met" => true, "rebuttal" => @rebuttal}])
        })

      assert Missions.inherited_contested(b) == []
    end

    test "a rebuttal too short to be an argument does not clear it" do
      a = mission!(%{artifacts: validation([unmet("FR-5", "no retry on 5xx responses")])})

      b =
        mission!(%{
          resumed_from: a.id,
          artifacts:
            validation([
              %{"req_id" => "FR-5", "met" => true, "rebuttal" => "fixed, see the diff"}
            ])
        })

      assert Missions.inherited_contested(b) != []
    end

    test "the freshest articulation of the fault is the one that carries forward" do
      a = mission!(%{artifacts: validation([unmet("FR-5", "no retry at all")])})

      b =
        mission!(%{
          resumed_from: a.id,
          artifacts: validation([unmet("FR-5", "retries exist but not on 503")])
        })

      assert Missions.inherited_contested(b) == [
               %{"req_id" => "FR-5", "reason" => "retries exist but not on 503"}
             ]
    end

    test "an unmet verdict with no evidence still names where it was reached" do
      a = mission!(%{artifacts: validation([%{"req_id" => "FR-5", "met" => false}])})

      assert Missions.inherited_contested(a) == [
               %{"req_id" => "FR-5", "reason" => "previously judged unmet in #{a.id}"}
             ]
    end

    test "the parent's own register is another lineage source, applied last" do
      a = mission!(%{artifacts: validation([unmet("FR-5", "from the artifact")])})

      b =
        mission!(%{
          resumed_from: a.id,
          contested_requirements: [%{"req_id" => "FR-5", "reason" => "from the register"}]
        })

      assert Missions.inherited_contested(b) == [
               %{"req_id" => "FR-5", "reason" => "from the register"}
             ]
    end

    test "a tournament's losing variants contest what they rejected" do
      a =
        mission!(%{
          artifacts: %{
            "validation_v1" => %{"requirements_met" => [unmet("FR-5", "v1 found no retry")]},
            "validation_v2" => %{"requirements_met" => [unmet("FR-6", "v2 found no backoff")]}
          }
        })

      assert Enum.map(Missions.inherited_contested(a), & &1["req_id"]) == ["FR-5", "FR-6"]
    end

    test "a lineage three deep is walked whole" do
      a = mission!(%{artifacts: validation([unmet("FR-5", "a said no")])})
      b = mission!(%{resumed_from: a.id, artifacts: validation([unmet("FR-6", "b said no")])})
      c = mission!(%{resumed_from: b.id, artifacts: validation([unmet("FR-7", "c said no")])})

      assert Missions.inherited_contested(c) == [
               %{"req_id" => "FR-5", "reason" => "a said no"},
               %{"req_id" => "FR-6", "reason" => "b said no"},
               %{"req_id" => "FR-7", "reason" => "c said no"}
             ]
    end

    test "a reaped ancestor truncates the walk instead of failing it" do
      b =
        mission!(%{
          resumed_from: "msn-long-gone",
          artifacts: validation([unmet("FR-5", "b said no")])
        })

      assert Missions.inherited_contested(b) == [
               %{"req_id" => "FR-5", "reason" => "b said no"}
             ]
    end

    test "a mission with no validation history contests nothing" do
      assert Missions.inherited_contested(mission!(%{artifacts: %{}})) == []
    end

    test "non-validation artifacts are not mined for verdicts" do
      a =
        mission!(%{
          artifacts: %{
            "exec_validation" => %{"requirements_met" => [unmet("FR-5", "not a verdict")]},
            "review" => %{"requirements_met" => [unmet("FR-6", "not a verdict either")]}
          }
        })

      assert Missions.inherited_contested(a) == []
    end

    test "malformed entries are ignored rather than poisoning the register" do
      a =
        mission!(%{
          artifacts:
            validation([
              unmet("FR-5", "real"),
              %{"met" => false},
              %{"req_id" => "", "met" => false},
              %{"req_id" => 7, "met" => false},
              "not a map"
            ])
        })

      assert Missions.inherited_contested(a) == [%{"req_id" => "FR-5", "reason" => "real"}]
    end
  end
end
