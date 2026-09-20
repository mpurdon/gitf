defmodule GiTF.Secrets do
  @moduledoc """
  One resolver for every runtime secret: environment first, then SSM
  Parameter Store, then nothing.

  ## Why this exists

  `/etc/gitf/gitf.env` was the only home for secrets on the box, maintained
  by hand. `rel/env.example` described a `fetch-secrets` step that rendered
  them from Parameter Store at boot; no such script was ever written, so the
  parameter and the file had to be updated together or they silently
  disagreed — and believing a Parameter Store update had taken effect when it
  had done nothing is a bad thing to be wrong about.

  Reading Parameter Store directly removes the second copy. Three things
  follow from it that the env file could not give:

    * **Rotation without a restart.** Systemd reads `EnvironmentFile=` at unit
      start, so a changed env file needs a restart, which kills in-flight
      missions. A changed parameter needs `expire/1`.
    * **Nothing on the root volume.** The env file is mode 0600, but any AMI,
      snapshot or root-volume backup carries its contents. A parameter stays
      in KMS-encrypted storage.
    * **Reads become auditable.** CloudTrail records every `GetParameter`.
      A file read leaves no trace anywhere.

  The IAM permission was already in place before any of this was written:
  `infra/aws/iam.tf` grants the instance role `ssm:GetParameter` on
  `parameter/gitf/*`, so nothing about the infrastructure changed.

  ## Resolution order, and why the environment wins

      1. the secret's environment variable
      2. SSM Parameter Store at /gitf/<name>, cached
      3. nil

  The environment is first so that a laptop, a test run and the one-shot CLI
  behave exactly as they did before this module existed — none of them has an
  instance role, and none of them should acquire an AWS dependency to read a
  value already sitting in the environment. It also gives an operator a way
  to override a parameter in an emergency without touching Parameter Store.

  ## What does NOT belong here

  Anything the BEAM reads before application code runs. `RELEASE_COOKIE` is
  consumed by the runtime itself, so there is no moment at which this module
  could supply it. `SECRET_KEY_BASE` and the signing salts are generated once
  by the installer and never rotated, so moving them would add a boot-time
  dependency on SSM in exchange for nothing. Those stay in the env file.

  ## Failure is always "absent", never a stall

  Every failure — no credentials, no such parameter, a throttle, an
  unreachable endpoint — resolves to `nil`, and callers already treat a
  missing secret as "this feature is off" (see `GiTF.SystemOne.enabled?/0`).
  A secret resolver that raised, or blocked, would convert a Parameter Store
  hiccup into an outage of whatever asked. Negative results are cached too,
  briefly, so a box with no AWS access does not pay the timeout on every
  call.
  """

  require Logger

  alias GiTF.AWS.Credentials

  @prefix "/gitf/"

  # A found secret is held for the life of the node: rotation goes through
  # expire/1, which is explicit and cheap, rather than through a TTL that
  # spends a network call on every process to cover a case that arises
  # roughly never.
  @negative_ttl_s 60

  @timeout_ms 3_000

  @typedoc """
  A secret's name: the environment variable, and the Parameter Store path
  under `/gitf/`, which is the downcased name with the `GITF_` prefix
  removed.
  """
  @type name :: String.t()

  # Every runtime secret, as {env var, parameter path}. Explicit rather than
  # derived, because the existing parameters were named before this module
  # and do not all follow one rule — /gitf/github_token, not
  # /gitf/gitf_github_token.
  @known %{
    "GITHUB_TOKEN" => "github_token",
    "GITF_GITHUB_WEBHOOK_SECRET" => "github_webhook_secret",
    "GITF_SENTRY_WEBHOOK_SECRET" => "sentry_webhook_secret",
    "GITF_SYSTEM_ONE_API_KEY" => "system_one_api_key"
  }

  # Provider API keys (ANTHROPIC_API_KEY and friends) are deliberately NOT
  # here, and adding them would be a mistake worth arguing about first.
  #
  # The factory runs on a Claude subscription through the CLI; a resident
  # provider key is what silently flips an in-process consumer onto a metered
  # API instead, which is the leak `GiTF.Runtime.LLMClient.impl/0` was changed
  # to close. If this resolver fetched them, parking a key in Parameter Store
  # — an action that reads as safe storage — would start a bill with no flag
  # flipped and nothing said. Provider keys stay in the environment, where
  # their presence is a deliberate local act.

  @doc "The secrets this module knows how to fetch, as env var names."
  @spec known() :: [name()]
  def known, do: @known |> Map.keys() |> Enum.sort()

  @doc """
  Fetches a secret, or `nil`.

  `name` is the environment variable. An unknown name is still read from the
  environment — so this is a safe drop-in for a bare `System.get_env/1` — but
  is never looked up in Parameter Store, because guessing a path would make
  a typo an AWS call instead of a `nil`.
  """
  @spec get(name()) :: String.t() | nil
  def get(name) when is_binary(name) do
    case present(System.get_env(name)) do
      nil -> from_parameter_store(name)
      value -> value
    end
  end

  @doc """
  Fetches a secret, raising if it is absent.

  For the few places where continuing without one would fail later and less
  clearly. Prefer `get/1` plus an explicit "feature off" branch wherever the
  feature can be off.
  """
  @spec fetch!(name()) :: String.t()
  def fetch!(name) do
    case get(name) do
      nil ->
        raise "secret #{name} is not set: absent from the environment" <>
                " and from SSM at #{@prefix}#{Map.get(@known, name, "(unmapped)")}"

      value ->
        value
    end
  end

  @doc """
  Drops a cached secret so the next `get/1` fetches it again.

  This is the rotation path: change the parameter, call this, done — no
  restart, so nothing in flight is lost. With no argument, drops everything.
  """
  @spec expire(name() | :all) :: :ok
  def expire(:all) do
    Enum.each(known(), &:persistent_term.erase({__MODULE__, &1}))
  end

  def expire(name) when is_binary(name) do
    :persistent_term.erase({__MODULE__, name})
    :ok
  end

  @doc """
  Where each known secret is actually coming from right now, for diagnostics.

  Reports `:env`, `:ssm`, or `:absent` per secret and never the values
  themselves — the point is to answer "did my Parameter Store change take
  effect?", which is exactly the question the old hand-maintained env file
  made unanswerable.
  """
  @spec sources() :: [{name(), :env | :ssm | :absent}]
  def sources do
    Enum.map(known(), fn name ->
      cond do
        present(System.get_env(name)) -> {name, :env}
        from_parameter_store(name) -> {name, :ssm}
        true -> {name, :absent}
      end
    end)
  end

  # -- Parameter Store ---------------------------------------------------------

  defp from_parameter_store(name) do
    case Map.fetch(@known, name) do
      {:ok, path} -> cached(name, path)
      :error -> nil
    end
  end

  defp cached(name, path) do
    now = System.system_time(:second)

    case :persistent_term.get({__MODULE__, name}, nil) do
      {:ok, value} ->
        value

      # A negative result is remembered only briefly: long enough that a
      # laptop with no instance role is not paying the IMDS timeout on every
      # call, short enough that creating the parameter starts working without
      # a restart.
      {:absent, at} when now - at < @negative_ttl_s ->
        nil

      _ ->
        fetch_and_cache(name, path, now)
    end
  end

  defp fetch_and_cache(name, path, now) do
    case fetch_parameter(path) do
      {:ok, value} ->
        :persistent_term.put({__MODULE__, name}, {:ok, value})
        Logger.info("secret #{name} resolved from SSM #{@prefix}#{path}")
        value

      :error ->
        :persistent_term.put({__MODULE__, name}, {:absent, now})
        nil
    end
  end

  defp fetch_parameter(path) do
    region = Credentials.default_region()

    with {:ok, creds} <- Credentials.resolve(region),
         {:ok, %{status: 200, body: body}} <- get_parameter(creds, region, path) do
      read_value(body)
    else
      {:error, :unavailable} ->
        # No credentials at all. Normal off EC2; not worth a line per secret,
        # and the negative cache stops it repeating.
        Logger.debug("secret #{@prefix}#{path}: no AWS credentials on this host")
        :error

      {:ok, %{status: 400} = resp} ->
        # ParameterNotFound arrives as a 400 and is entirely expected for a
        # secret this deployment does not use. Any OTHER 400 is a real fault
        # and must not hide behind it.
        if not_found?(resp) do
          Logger.debug("secret #{@prefix}#{path}: no such parameter")
        else
          warn(path, resp)
        end

        :error

      {:ok, resp} ->
        # 403 is the one that cost an afternoon: a SigV4 signature computed
        # over different bytes or a different header set than were sent looks
        # exactly like a missing secret from the outside. `absent` in
        # health_check with nothing in the journal is not a diagnosis, so
        # anything unexpected is a warning, loudly, with the status.
        warn(path, resp)
        :error

      {:error, reason} ->
        Logger.warning("secret #{@prefix}#{path}: SSM unreachable — #{inspect(reason, limit: 5)}")
        :error
    end
  rescue
    error ->
      Logger.warning("secret #{@prefix}#{path}: lookup raised — #{Exception.message(error)}")
      :error
  end

  defp warn(path, %{status: status, body: body}) do
    Logger.warning(
      "secret #{@prefix}#{path}: SSM returned #{status} — #{error_code(body) || inspect(body, limit: 3)}. " <>
        "Falling back to absent; check the instance role's ssm:GetParameter and kms:Decrypt."
    )
  end

  defp not_found?(%{body: body}), do: error_code(body) == "ParameterNotFound"

  defp error_code(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> error_code(decoded)
      _ -> nil
    end
  end

  defp error_code(%{"__type" => type}) when is_binary(type),
    do: type |> String.split("#") |> List.last()

  defp error_code(_), do: nil

  defp get_parameter(creds, region, path) do
    # The JSON protocol, not the query API: one POST, no URL encoding of a
    # path full of slashes.
    #
    # Built the way GiTF.Runtime.BedrockDirect builds its signed request, and
    # for the reason its comment gives: SigV4 signs the body hash and the
    # exact header set, so anything that changes either between signing and
    # sending invalidates the signature. Two specifics, both of which I got
    # wrong first time and which fail as a silent 403:
    #
    #   * `body:` with a pre-serialized string, not `json:` — the signer must
    #     hash the same bytes that go on the wire.
    #   * `compressed: false` to suppress Req's accept-encoding step, so the
    #     header set is deterministic.
    body = Jason.encode!(%{"Name" => @prefix <> path, "WithDecryption" => true})

    Req.new(
      url: "https://ssm.#{region}.amazonaws.com/",
      method: :post,
      body: body,
      headers: %{
        "content-type" => "application/x-amz-json-1.1",
        "x-amz-target" => "AmazonSSM.GetParameter"
      },
      receive_timeout: @timeout_ms,
      compressed: false,
      retry: false
    )
    |> AWSAuth.Req.attach(credentials: creds, service: "ssm", region: region)
    |> Req.request()
  end

  defp read_value(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> read_value(decoded)
      _ -> :error
    end
  end

  defp read_value(%{"Parameter" => %{"Value" => value}}) do
    case present(value) do
      nil -> :error
      v -> {:ok, v}
    end
  end

  defp read_value(_), do: :error

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: String.trim(value) |> nilify_empty()
  defp present(_), do: nil

  defp nilify_empty(""), do: nil
  defp nilify_empty(value), do: value
end
