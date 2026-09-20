defmodule GiTF.SystemOne do
  @moduledoc """
  Mockable wrapper around TypeSafe's System One API (the Jev model).

  A System One model is not an LLM and is not used like one here. It takes a
  `state` and a map of typed questions, and returns typed answers with a
  calibrated probability distribution and a `confidence` derived from that
  distribution's shape. It writes no prose, calls no tools, and cannot be
  asked to do either.

  That narrowness is the reason it is here. Several decisions in the factory
  are a choice from a fixed set — which failure class, which sector, whether
  a diff satisfies a goal — and today they are made either by substring
  matching (precise but blind to anything unseen) or by asking a generative
  model for a verdict it states with the same flatness whether it is sure or
  guessing. A calibrated probability gives the third answer neither of those
  can: *I do not know*, as a number you can threshold on.

  ## Fail closed, always

  Every caller must supply what to do when this module returns an error, and
  that fallback must be the conservative answer — the one the factory would
  have reached without it. A judge that fails open is worse than no judge: it
  converts a network blip into a permissive decision. `GiTF.Budget` and the
  security scan learned this the hard way (see the 2026-08-28 BEAM audit on
  fail-open rescues), and nothing here repeats it.

  For the same reason `timeout_ms` is short by default. This runs on paths
  that have already failed, and a dying ghost worker can afford two seconds;
  nothing in the factory should wait longer on a third party to be told
  something it already has a usable answer for.

  ## Cost

  Jev bills input tokens only, at roughly \\$0.042 per million (output is
  free). A two-thousand-token judgement is about eight thousandths of a
  cent. That is what makes it reasonable to judge things the factory
  currently does not judge at all — but it is still a metered third-party
  API, so `enabled?/0` requires BOTH an explicit flag and a key, and no
  chat-reachable config key can turn it on (see `GiTF.Config.Settable`).

  ## Configuration

      config :gitf, :system_one_enabled, true
      config :gitf, :system_one_model, "jev-latest"
      config :gitf, :system_one_timeout_ms, 2_000

  The key comes from `GITF_SYSTEM_ONE_API_KEY` (or `TYPESAFE_API_KEY`), never
  from config — it is a secret, and config is readable by anything that can
  read the config. On the box it lives in `/etc/gitf/gitf.env`, which is
  operator-maintained: SSM Parameter Store holds the copy of record (free, at
  Standard tier) but nothing renders it automatically, so the env file and the
  parameter are written together or they drift. Systemd reads
  `EnvironmentFile=` at unit start, so a new key needs a restart — the flag
  next to it does not.

  Tests swap the whole module out:

      config :gitf, :system_one_client, GiTF.Test.ScriptedSystemOne
  """

  require Logger

  @endpoint "https://api.typesafe.ai/v1/systemone"
  @default_model "jev-latest"
  @default_timeout_ms 2_000

  @typedoc """
  One question. `:choice` picks from `criteria` (a map of option name to a
  description the model reads); `:score` rates against ordered levels;
  `:noul` returns the probability that a yes/no claim is true.
  """
  @type question :: map()

  @typedoc """
  One answer. Choice and Score carry `:confidence`; Noul carries only a
  probability, so callers threshold on that directly.
  """
  @type answer :: %{
          optional(:choice) => String.t(),
          optional(:score) => number(),
          optional(:noul) => number(),
          optional(:confidence) => number(),
          optional(:probabilities) => %{String.t() => number()}
        }

  @callback ask(state :: term(), questions :: %{String.t() => question()}, opts :: keyword()) ::
              {:ok, %{answers: %{String.t() => answer()}, model: String.t(), usage: map()}}
              | {:error, term()}

  @doc "The configured implementation. Tests set `:system_one_client`."
  @spec impl() :: module()
  def impl, do: Application.get_env(:gitf, :system_one_client, __MODULE__.Default)

  @doc """
  Asks one or more questions about `state`.

  Jev ingests the state once and evaluates every question against it in
  parallel, so asking five questions in one call costs barely more than
  asking one — pack them rather than making a call per decision.
  """
  @spec ask(term(), %{String.t() => question()}, keyword()) :: {:ok, map()} | {:error, term()}
  def ask(state, questions, opts \\ []), do: impl().ask(state, questions, opts)

  @doc """
  Whether System One may be called at all: an explicit flag AND a key.

  Both, because the flag alone on a box with no key would make every judged
  decision take the timeout before falling back, and a key alone should not
  start spending because it happens to be present in the environment.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:gitf, :system_one_enabled, false) and api_key() != nil
  end

  @doc """
  The API key. Never from config — config is readable by anything that can
  read the config.

  `GiTF.Secrets` resolves it from the environment first, then SSM Parameter
  Store, so on the box the key need not exist on disk at all.
  `TYPESAFE_API_KEY` is honoured as a second env name because it is what
  their own SDKs read, and a key already exported for a local script should
  just work.
  """
  @spec api_key() :: String.t() | nil
  def api_key do
    GiTF.Secrets.get("GITF_SYSTEM_ONE_API_KEY") ||
      case System.get_env("TYPESAFE_API_KEY") do
        k when is_binary(k) and k != "" -> k
        _ -> nil
      end
  end

  @doc "The one endpoint every question goes to."
  @spec endpoint() :: String.t()
  def endpoint, do: @endpoint

  @doc "The model to send. `jev-latest` unless pinned."
  @spec model() :: String.t()
  def model, do: Application.get_env(:gitf, :system_one_model, @default_model)

  @doc "How long to wait before falling back to the conservative answer."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: Application.get_env(:gitf, :system_one_timeout_ms, @default_timeout_ms)

  # -- Question builders -------------------------------------------------------

  @doc """
  A Choice question: pick one of `criteria`.

  `criteria` is a map of option name to a description of that option. Both
  the names and the descriptions are sent, and the model never sees the
  question id — so the descriptions are the only thing separating one option
  from another. Write them to contrast, not to define in isolation.
  """
  @spec choice(String.t(), %{String.t() => String.t()}) :: question()
  def choice(instructions, criteria) when is_binary(instructions) and is_map(criteria) do
    %{"type" => "choice", "instructions" => instructions, "criteria" => criteria}
  end

  @doc """
  A Noul question: the probability that a yes/no claim is true.

  Noul answers carry no `confidence` — the probability *is* the uncertainty,
  so threshold on how far it sits from 0.5 rather than looking for a
  confidence field that will not be there.
  """
  @spec noul(String.t()) :: question()
  def noul(instructions) when is_binary(instructions) do
    %{"type" => "noul", "instructions" => instructions}
  end

  @doc """
  A Score question: rate against ordered levels, lowest first.

  The returned score is continuous and can sit between levels, which is the
  point — it is a position on the scale, not a bucket.
  """
  @spec score(String.t(), [String.t()]) :: question()
  def score(instructions, levels) when is_binary(instructions) and is_list(levels) do
    %{"type" => "score", "instructions" => instructions, "criteria" => levels}
  end

  # -- Answer readers ----------------------------------------------------------

  @doc """
  Reads a Choice answer as `{:ok, option, confidence}`.

  Returns `{:error, :no_answer}` when the id is absent or the answer is not
  a choice, so a malformed or partial response is a fallback rather than a
  crash in whatever was being judged.
  """
  @spec read_choice(map(), String.t()) :: {:ok, String.t(), float()} | {:error, :no_answer}
  def read_choice(%{answers: answers}, id) when is_map(answers) do
    case Map.get(answers, id) do
      %{"choice" => c} = a when is_binary(c) ->
        {:ok, c, confidence_of(a)}

      %{choice: c} = a when is_binary(c) ->
        {:ok, c, confidence_of(a)}

      _ ->
        {:error, :no_answer}
    end
  end

  def read_choice(_, _), do: {:error, :no_answer}

  @doc "The full probability distribution for an answer, or an empty map."
  @spec probabilities(map(), String.t()) :: %{String.t() => number()}
  def probabilities(%{answers: answers}, id) when is_map(answers) do
    case Map.get(answers, id) do
      %{"probabilities" => p} when is_map(p) -> p
      %{probabilities: p} when is_map(p) -> p
      _ -> %{}
    end
  end

  def probabilities(_, _), do: %{}

  defp confidence_of(%{"confidence" => c}) when is_number(c), do: c / 1
  defp confidence_of(%{confidence: c}) when is_number(c), do: c / 1
  # No confidence field means we cannot tell how sure it was, which has to
  # read as "not sure" — every caller thresholds upward.
  defp confidence_of(_), do: 0.0

  defmodule Default do
    @moduledoc """
    The live implementation: one `POST /v1/systemone` with a bearer token.

    There is no Elixir SDK, which costs nothing — the API is a single JSON
    endpoint. Retries are deliberately absent: the callers here all have a
    conservative fallback and run on paths that are already failing, so a
    second attempt buys a little accuracy for a doubled wait. The client
    SDKs retry on 429 because their callers have nothing else to do; ours
    do.
    """
    @behaviour GiTF.SystemOne

    require Logger

    @impl true
    def ask(state, questions, opts) do
      case GiTF.SystemOne.api_key() do
        nil ->
          {:error, :no_api_key}

        key ->
          post(state, questions, key, opts)
      end
    end

    defp post(state, questions, key, opts) do
      body = %{
        "model" => Keyword.get(opts, :model, GiTF.SystemOne.model()),
        "state" => state,
        "questions" => questions
      }

      timeout = Keyword.get(opts, :timeout_ms, GiTF.SystemOne.timeout_ms())

      request =
        Req.new(
          url: GiTF.SystemOne.endpoint(),
          headers: [
            {"authorization", "Bearer " <> key},
            {"content-type", "application/json"}
          ],
          json: body,
          receive_timeout: timeout,
          retry: false
        )

      case Req.post(request) do
        {:ok, %{status: 200, body: %{"answers" => answers} = resp}} ->
          {:ok,
           %{
             answers: answers,
             model: Map.get(resp, "model"),
             usage: Map.get(resp, "usage", %{})
           }}

        {:ok, %{status: 429}} ->
          # Their own docs warn limits move without notice while they absorb
          # demand. Distinguished from a generic failure so a caller can log
          # "throttled" rather than "broken".
          {:error, :rate_limited}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("System One: HTTP #{status}: #{inspect(body, limit: 5)}")
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
