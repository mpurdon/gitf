defmodule GiTF.Eval.Helpers do
  @moduledoc """
  Shared scoring helpers for `GiTF.Eval.Scenario` implementations.

  Scenarios that rank a list of candidates against an expected answer
  follow the same pass/fail shape: locate the expected answer's rank
  in the candidate list, pass if rank ≤ `min_rank`, fail otherwise.
  This module centralises the rank-and-verdict logic so each scenario
  only declares its cases + how to invoke the system under test.
  """

  @doc """
  1-indexed position of `expected` in `candidates`, or `nil` if absent.

  Pass `match_fn/1` to compare a candidate against `expected` when the
  default `==` doesn't fit (e.g., when the candidate is a struct and
  `expected` is a name string).

      iex> GiTF.Eval.Helpers.find_rank(["a", "b", "c"], "b")
      2

      iex> GiTF.Eval.Helpers.find_rank([%{name: "a"}, %{name: "b"}], "b", & &1.name)
      2

      iex> GiTF.Eval.Helpers.find_rank(["a"], "missing")
      nil
  """
  @spec find_rank([term()], term(), (term() -> term())) :: pos_integer() | nil
  def find_rank(candidates, expected, key_fn \\ & &1)

  def find_rank(candidates, expected, key_fn) when is_list(candidates) do
    case Enum.find_index(candidates, &(key_fn.(&1) == expected)) do
      nil -> nil
      idx -> idx + 1
    end
  end

  @doc """
  Converts a found-rank + min_rank pair into a `GiTF.Eval.Scenario`
  result tuple. `labels` is what to echo back as `top_k` in the meta
  map for human-readable failure reports.
  """
  @spec rank_verdict(pos_integer() | nil, [term()], pos_integer(), pos_integer()) ::
          GiTF.Eval.Scenario.result()
  def rank_verdict(rank, labels, min_rank, top_k)
      when is_list(labels) and is_integer(min_rank) and is_integer(top_k) do
    cond do
      is_nil(rank) ->
        {:fail, %{rank: nil, top_k: labels, reason: "expected not in top-#{top_k}"}}

      rank <= min_rank ->
        {:pass, %{rank: rank, top_k: labels}}

      true ->
        {:fail, %{rank: rank, top_k: labels, reason: "rank #{rank} > min_rank #{min_rank}"}}
    end
  end
end
