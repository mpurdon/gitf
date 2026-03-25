defmodule GiTF.Runtime.Keys do
  @moduledoc """
  Loads API keys from `.gitf/config.toml` and AWS credentials into environment variables.

  Reads the TOML file directly — no dependency on OTP app, GenServers, or
  ETS tables. Works in all contexts: CLI commands, full OTP app, escript.

  Keys are only set if not already present in the environment, so explicit
  env vars always win.

  ## Example config.toml

      [llm.keys]
      anthropic = "sk-ant-..."
      openai = "sk-..."
      google = "AIza..."

      # AWS credentials from ~/.aws/credentials
      aws_profile = "nieto"        # profile name (default: "default")
  """

  require Logger

  @key_env_map %{
    "anthropic" => "ANTHROPIC_API_KEY",
    "openai" => "OPENAI_API_KEY",
    "google" => "GOOGLE_API_KEY",
    "groq" => "GROQ_API_KEY",
    "mistral" => "MISTRAL_API_KEY",
    "cohere" => "COHERE_API_KEY",
    "together" => "TOGETHER_API_KEY",
    "fireworks" => "FIREWORKS_API_KEY"
  }

  @aws_env_map %{
    "aws_access_key_id" => "AWS_ACCESS_KEY_ID",
    "aws_secret_access_key" => "AWS_SECRET_ACCESS_KEY",
    "aws_session_token" => "AWS_SESSION_TOKEN",
    "aws_security_token" => "AWS_SESSION_TOKEN",
    "aws_region" => "AWS_REGION"
  }

  @doc """
  Loads API keys from `.gitf/config.toml` and AWS credentials into environment variables.

  Only sets keys that are not already present in the environment.
  Returns the number of keys loaded.
  """
  @spec load() :: non_neg_integer()
  def load do
    keys = read_keys_from_toml()

    loaded =
      Enum.count(keys, fn {raw_key, value} ->
        env_var = resolve_env_var(raw_key)

        if env_var && System.get_env(env_var) == nil and is_binary(value) and value != "" do
          System.put_env(env_var, value)
          true
        else
          false
        end
      end)

    # Load AWS credentials from ~/.aws/credentials if configured
    aws_loaded = load_aws_credentials(keys)

    total = loaded + aws_loaded

    if total > 0 do
      Logger.info("Loaded #{total} key(s) (#{loaded} API, #{aws_loaded} AWS)")
    end

    total
  rescue
    e ->
      Logger.debug("Failed to load API keys: #{inspect(e)}")
      0
  end

  @doc """
  Returns a diagnostic status of which API keys are available.
  """
  @spec status() :: [{String.t(), boolean()}]
  def status do
    api_keys = Enum.map(@key_env_map, fn {provider, env_var} ->
      {provider, System.get_env(env_var) != nil}
    end)

    aws_status = {"aws_bedrock",
      System.get_env("AWS_ACCESS_KEY_ID") != nil or
      System.get_env("AWS_BEARER_TOKEN_BEDROCK") != nil}

    api_keys ++ [aws_status]
  end

  # -- Private -----------------------------------------------------------------

  # Provider is started before Keys.load(), so we can read from ETS
  defp read_keys_from_toml do
    case GiTF.Config.Provider.get([:llm, :keys]) do
      keys when is_map(keys) ->
        Map.new(keys, fn {k, v} -> {to_string(k), v} end)
        |> Map.filter(fn {_k, v} -> is_binary(v) and v != "" end)
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  # "google" -> "GOOGLE_API_KEY", "google_api_key" -> "GOOGLE_API_KEY"
  defp resolve_env_var(raw_key) do
    normalized =
      raw_key
      |> to_string()
      |> String.replace(~r/_api_key$/, "")

    Map.get(@key_env_map, normalized)
  end

  # -- AWS credentials loading -------------------------------------------------

  defp load_aws_credentials(toml_keys) do
    # Skip if AWS creds are already in the environment
    if System.get_env("AWS_ACCESS_KEY_ID") != nil or
       System.get_env("AWS_BEARER_TOKEN_BEDROCK") != nil do
      0
    else
      profile = resolve_aws_profile(toml_keys)
      load_aws_profile(profile)
    end
  end

  defp resolve_aws_profile(toml_keys) do
    # Priority: config.toml aws_profile > AWS_PROFILE env var > "default"
    cond do
      profile = toml_keys["aws_profile"] -> to_string(profile)
      profile = System.get_env("AWS_PROFILE") -> profile
      true -> "default"
    end
  end

  @doc "Loads AWS credentials from ~/.aws/credentials or SSO for the given profile."
  def load_aws_profile(profile) do
    creds_path = Path.join(System.user_home!(), ".aws/credentials")
    config_path = Path.join(System.user_home!(), ".aws/config")

    # Try static credentials file first
    loaded =
      case parse_ini_file(creds_path) do
        {:ok, sections} ->
          case Map.get(sections, profile) do
            nil -> 0
            creds -> set_aws_env_vars(creds)
          end
        {:error, _} -> 0
      end

    # If no static creds found, try SSO via `aws configure export-credentials`
    loaded =
      if loaded == 0 do
        load_aws_sso_credentials(profile)
      else
        loaded
      end

    # Also check ~/.aws/config for region if not set
    if System.get_env("AWS_REGION") == nil do
      load_aws_region(config_path, profile)
    end

    if loaded > 0 do
      Logger.info("Loaded AWS credentials from profile '#{profile}'")
    end

    loaded
  end

  defp load_aws_sso_credentials(profile) do
    case System.cmd("aws", ["configure", "export-credentials", "--profile", profile, "--format", "env"],
           stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.count(fn line ->
          case String.split(line, "=", parts: 2) do
            ["export " <> var, value] ->
              var = String.trim(var)
              value = String.trim(value)
              if var in ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"] do
                System.put_env(var, value)
                true
              else
                false
              end
            _ -> false
          end
        end)

      {error, _} ->
        Logger.debug("SSO credential export failed for profile '#{profile}': #{String.slice(error, 0, 200)}")
        0
    end
  rescue
    e ->
      Logger.debug("SSO credential export error: #{Exception.message(e)}")
      0
  end

  defp set_aws_env_vars(creds) do
    Enum.count(creds, fn {key, value} ->
      env_var = Map.get(@aws_env_map, key)

      if env_var && System.get_env(env_var) == nil && is_binary(value) && value != "" do
        System.put_env(env_var, value)
        true
      else
        false
      end
    end)
  end

  defp load_aws_region(config_path, profile) do
    # In ~/.aws/config, profiles are named [profile X] except for [default]
    config_section = if profile == "default", do: "default", else: "profile #{profile}"

    case parse_ini_file(config_path) do
      {:ok, sections} ->
        case Map.get(sections, config_section) do
          %{"region" => region} when region != "" ->
            System.put_env("AWS_REGION", region)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  # -- INI file parser ---------------------------------------------------------

  @doc false
  @spec parse_ini_file(String.t()) :: {:ok, map()} | {:error, term()}
  def parse_ini_file(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, parse_ini(content)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_ini(content) do
    content
    |> String.split("\n")
    |> Enum.reduce({%{}, nil}, fn line, {sections, current_section} ->
      line = String.trim(line)

      cond do
        # Empty line or comment
        line == "" or String.starts_with?(line, "#") or String.starts_with?(line, ";") ->
          {sections, current_section}

        # Section header: [profile_name]
        String.starts_with?(line, "[") and String.ends_with?(line, "]") ->
          section = line |> String.slice(1..-2//1) |> String.trim()
          {Map.put_new(sections, section, %{}), section}

        # Key = value pair
        current_section != nil and String.contains?(line, "=") ->
          [key | rest] = String.split(line, "=", parts: 2)
          key = String.trim(key)
          value = rest |> Enum.join("=") |> String.trim()
          section_data = Map.get(sections, current_section, %{})
          updated = Map.put(section_data, key, value)
          {Map.put(sections, current_section, updated), current_section}

        true ->
          {sections, current_section}
      end
    end)
    |> elem(0)
  end
end
