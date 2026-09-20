defmodule GiTF.AWS.Credentials do
  @moduledoc """
  AWS credentials for SigV4, from resident env keys or the EC2 instance role.

  Extracted from `GiTF.Runtime.BedrockDirect`, which had the only copy. It
  now has a second caller (`GiTF.Secrets`, reading SSM Parameter Store), and
  two copies of an expiry-cached credential fetch is two places for the
  expiry rule to drift — which is the kind of bug that surfaces as a 403 an
  hour into an unattended run and nowhere else.

  Resolution order:

    1. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (plus
       `AWS_SESSION_TOKEN` when present), but only while
       `GiTF.Runtime.Keys.env_creds_expired?/0` says they are still good —
       an expired resident key set must not shadow a working instance role.
    2. IMDSv2 instance-role credentials, cached in `:persistent_term` until
       five minutes before they expire.

  There is deliberately no third step. A box with neither is not
  misconfigured in a way a fallback could rescue.
  """

  require Logger

  @imds_base "http://169.254.169.254"
  @imds_opts [receive_timeout: 2_000, retry: false]

  # How long before real expiry to stop trusting cached credentials. Five
  # minutes so a long-running signed request cannot outlive them mid-flight.
  @expiry_margin_s 300

  @doc """
  Credentials for `region`, or `{:error, :unavailable}` when there are none.

  Callers decide what "no credentials" means for them: `BedrockDirect` raises
  (a model call with no auth has no useful degraded form), while
  `GiTF.Secrets` treats it as "this secret is not available here", which is
  the correct answer on a laptop.
  """
  @spec resolve(String.t()) :: {:ok, struct()} | {:error, :unavailable}
  def resolve(region) when is_binary(region) do
    access_key = System.get_env("AWS_ACCESS_KEY_ID")
    secret_key = System.get_env("AWS_SECRET_ACCESS_KEY")
    session_token = System.get_env("AWS_SESSION_TOKEN")

    if access_key && secret_key && not GiTF.Runtime.Keys.env_creds_expired?() do
      creds = %{
        access_key_id: access_key,
        secret_access_key: secret_key,
        region: region
      }

      creds = if session_token, do: Map.put(creds, :session_token, session_token), else: creds
      {:ok, AWSAuth.Credentials.from_map(creds)}
    else
      case instance_role_credentials() do
        {:ok, creds} -> {:ok, AWSAuth.Credentials.from_map(Map.put(creds, :region, region))}
        :error -> {:error, :unavailable}
      end
    end
  end

  @doc """
  Whether this host can authenticate to AWS at all.

  Cheap after the first call, because it goes through the same cache — so it
  is safe to ask on a hot path before deciding whether an AWS-backed feature
  is available.
  """
  @spec available?(String.t()) :: boolean()
  def available?(region \\ default_region()) do
    match?({:ok, _}, resolve(region))
  end

  @doc "The region to sign for: `AWS_REGION`, then `AWS_DEFAULT_REGION`, then us-east-1."
  @spec default_region() :: String.t()
  def default_region do
    System.get_env("AWS_REGION") || System.get_env("AWS_DEFAULT_REGION") || "us-east-1"
  end

  # -- IMDSv2 ------------------------------------------------------------------

  defp instance_role_credentials do
    now = System.system_time(:second)

    case :persistent_term.get({__MODULE__, :imds_creds}, nil) do
      %{expires_at: exp} = cached when exp - @expiry_margin_s > now ->
        {:ok, Map.delete(cached, :expires_at)}

      _ ->
        fetch_imds_credentials(now)
    end
  end

  defp fetch_imds_credentials(now) do
    with {:ok, %{status: 200, body: token}} <-
           Req.put(
             @imds_base <> "/latest/api/token",
             [headers: %{"x-aws-ec2-metadata-token-ttl-seconds" => "21600"}] ++ @imds_opts
           ),
         hdrs = %{"x-aws-ec2-metadata-token" => token},
         {:ok, %{status: 200, body: role_body}} <-
           Req.get(
             @imds_base <> "/latest/meta-data/iam/security-credentials/",
             [headers: hdrs] ++ @imds_opts
           ),
         role when is_binary(role) <-
           role_body |> to_string() |> String.split("\n", trim: true) |> List.first(),
         {:ok, %{status: 200, body: body}} <-
           Req.get(
             @imds_base <> "/latest/meta-data/iam/security-credentials/" <> role,
             [headers: hdrs] ++ @imds_opts
           ) do
      data = if is_binary(body), do: Jason.decode!(body), else: body

      # An unparseable Expiration must NOT invent an hour of validity. This
      # sits just past the expiry margin on purpose: 360s expiry minus the
      # 300s margin leaves 60s of usable cache, so a real expiry we failed to
      # read cannot outlive our belief in it by more than a minute.
      expires_at =
        case DateTime.from_iso8601(data["Expiration"] || "") do
          {:ok, dt, _} -> DateTime.to_unix(dt)
          _ -> now + @expiry_margin_s + 60
        end

      creds = %{
        access_key_id: data["AccessKeyId"],
        secret_access_key: data["SecretAccessKey"],
        session_token: data["Token"],
        expires_at: expires_at
      }

      :persistent_term.put({__MODULE__, :imds_creds}, creds)
      {:ok, Map.delete(creds, :expires_at)}
    else
      _ -> :error
    end
  rescue
    # IMDS is unreachable off EC2, which is the normal case on a laptop.
    _ -> :error
  end
end
