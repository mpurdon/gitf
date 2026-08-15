defmodule GiTF.CLI.SelfUpdate do
  @moduledoc """
  `gitf self-update` — replaces the running escript with the latest
  GitHub Release build.

  CI publishes every main build as a GitHub Release with the escript
  attached, so updates are plain unauthenticated HTTPS downloads. The new
  binary streams to a staging file beside the target (so the final rename
  is atomic), its version is read out of the archive without executing it,
  and only then does it replace the running binary. Only escript installs
  can self-update; the daemon release on the box deploys via
  `rel/install-systemd.sh`, and brew installs prefer `brew upgrade`.
  """

  alias GiTF.CLI.Format

  @repo "mpurdon/gitf"

  def run(_result) do
    case update() do
      :ok ->
        :ok

      :up_to_date ->
        Format.info("Already up to date (gitf #{GiTF.version()}).")

      {:error, message} ->
        Format.error(message)
        System.halt(1)
    end
  end

  defp update do
    with {:ok, target} <- escript_path(),
         {:ok, latest} <- latest_release_version(),
         :ok <- worth_updating(latest),
         staged = target <> ".self-update",
         {:ok, new_version} <- fetch_and_verify(latest, staged) do
      File.chmod!(staged, 0o755)
      File.rename!(staged, target)
      Format.success("Updated gitf #{GiTF.version()} -> #{new_version} at #{target}")

      if String.contains?(target, "/Cellar/") do
        Format.warn("This looks like a Homebrew install — `brew upgrade gitf` will overwrite it.")
      end

      :ok
    end
  end

  # -- Steps -------------------------------------------------------------------

  defp escript_path do
    if :init.get_argument(:gitf_escript) == :error do
      {:error,
       "self-update only works for escript installs. " <>
         "The daemon release updates via rel/install-systemd.sh."}
    else
      {:ok, :escript.script_name() |> to_string() |> Path.expand()}
    end
  end

  defp latest_release_version do
    case Req.get("https://api.github.com/repos/#{@repo}/releases/latest",
           headers: [{"accept", "application/vnd.github+json"}]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"tag_name" => "v" <> version}}} ->
        {:ok, version}

      {:ok, %Req.Response{status: 404}} ->
        {:error,
         "no GitHub Release found for #{@repo} — the first release lands with the next main build."}

      {:ok, %Req.Response{status: status}} ->
        {:error, "GitHub API returned HTTP #{status} looking up the latest release."}

      {:error, err} ->
        {:error, "could not reach GitHub: #{Exception.message(err)}"}
    end
  end

  defp worth_updating(latest) do
    if latest == GiTF.version(), do: :up_to_date, else: :ok
  end

  # Downloads and validates the new escript at `staged`; on any failure the
  # (possibly partial) staging file is removed in this one place.
  defp fetch_and_verify(version, staged) do
    with {:ok, _} <- download(version, staged),
         {:ok, new_version} <- archive_version(staged) do
      {:ok, new_version}
    else
      {:error, message} ->
        File.rm(staged)
        {:error, message}
    end
  end

  defp download(version, dest) do
    url = "https://github.com/#{@repo}/releases/download/v#{version}/gitf"

    case Req.get(url, into: File.stream!(dest)) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, dest}

      {:ok, %Req.Response{status: status}} ->
        {:error, "download of #{url} failed with HTTP #{status}."}

      {:error, err} ->
        {:error, "download of #{url} failed: #{Exception.message(err)}"}
    end
  end

  @doc """
  Reads the app version out of an escript without executing it.

  An escript is a shebang header followed by a zip archive; the version
  lives in the embedded `gitf.app` spec, which is the only archive member
  extracted. Public for tests.
  """
  def archive_version(path) do
    app_file? = fn
      {:zip_file, name, _info, _comment, _offset, _comp_size} ->
        String.ends_with?(to_string(name), "/gitf.app")

      _ ->
        false
    end

    with {:ok, bin} <- File.read(path),
         {zip_start, _} <- :binary.match(bin, <<"PK", 3, 4>>),
         zip = binary_part(bin, zip_start, byte_size(bin) - zip_start),
         {:ok, [{_name, app_spec} | _]} <-
           :zip.extract(zip, [:memory, {:file_filter, app_file?}]),
         {:ok, tokens, _} <- :erl_scan.string(String.to_charlist(to_string(app_spec))),
         {:ok, {:application, :gitf, props}} <- :erl_parse.parse_term(tokens) do
      {:ok, props |> Keyword.fetch!(:vsn) |> to_string()}
    else
      _ -> {:error, "downloaded file is not a gitf escript (no readable gitf.app inside)."}
    end
  end
end
