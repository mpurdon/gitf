defmodule GiTF.CLI.SelfUpdate do
  @moduledoc """
  `gitf self-update` — replaces the running escript with the latest
  GitHub Release build.

  CI publishes every main build as a GitHub Release with the escript
  attached, so updates are plain unauthenticated HTTPS downloads. The new
  binary's version is read out of the archive without executing it, then
  the swap is atomic (same-directory rename). Only escript installs can
  self-update; the daemon release on the box deploys via
  `rel/install-systemd.sh`, and brew installs prefer `brew upgrade`.
  """

  alias GiTF.CLI.Format

  @repo "mpurdon/gitf"

  def run(_result) do
    with {:ok, target} <- escript_path(),
         {:ok, latest} <- latest_release_version(),
         :ok <- check_worth_updating(latest),
         {:ok, tmp_dir, new_binary} <- download(latest),
         {:ok, new_version} <- archive_version(new_binary) do
      install(new_binary, target)
      File.rm_rf(tmp_dir)
      Format.success("Updated gitf #{GiTF.version()} -> #{new_version} at #{target}")

      if String.contains?(target, "/Cellar/") do
        Format.warn("This looks like a Homebrew install — `brew upgrade gitf` will overwrite it.")
      end

      :ok
    else
      :up_to_date ->
        Format.info("Already up to date (gitf #{GiTF.version()}).")

      {:error, message} ->
        Format.error(message)
        System.halt(1)
    end
  end

  # -- Steps -------------------------------------------------------------------

  defp escript_path do
    {:ok, :escript.script_name() |> to_string() |> Path.expand()}
  rescue
    _ -> {:error, escript_only_message()}
  catch
    _, _ -> {:error, escript_only_message()}
  end

  defp escript_only_message do
    "self-update only works for escript installs. " <>
      "The daemon release updates via rel/install-systemd.sh."
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

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, "could not reach GitHub: #{reason}"}

      {:error, err} ->
        {:error, "could not reach GitHub: #{Exception.message(err)}"}
    end
  end

  defp check_worth_updating(latest) do
    if latest == GiTF.version(), do: :up_to_date, else: :ok
  end

  defp download(version) do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "gitf-self-update-#{System.system_time(:millisecond)}"
      )

    File.mkdir_p!(tmp_dir)
    binary = Path.join(tmp_dir, "gitf")
    url = "https://github.com/#{@repo}/releases/download/v#{version}/gitf"

    case Req.get(url, into: File.stream!(binary)) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, tmp_dir, binary}

      {:ok, %Req.Response{status: status}} ->
        File.rm_rf(tmp_dir)
        {:error, "download of #{url} failed with HTTP #{status}."}

      {:error, err} ->
        File.rm_rf(tmp_dir)
        {:error, "download of #{url} failed: #{Exception.message(err)}"}
    end
  end

  @doc """
  Reads the app version out of an escript without executing it.

  An escript is a shebang header followed by a zip archive; the version
  lives in the embedded `gitf.app` spec. Public for tests.
  """
  def archive_version(path) do
    with {:ok, bin} <- File.read(path),
         {zip_start, _} <- :binary.match(bin, <<"PK", 3, 4>>),
         zip = binary_part(bin, zip_start, byte_size(bin) - zip_start),
         {:ok, files} <- :zip.extract(zip, [:memory]),
         {_, app_spec} <-
           Enum.find(files, :error, fn {name, _} ->
             String.ends_with?(to_string(name), "/gitf.app")
           end),
         {:ok, tokens, _} <- :erl_scan.string(String.to_charlist(to_string(app_spec))),
         {:ok, {:application, :gitf, props}} <- :erl_parse.parse_term(ensure_dot(tokens)) do
      {:ok, props |> Keyword.fetch!(:vsn) |> to_string()}
    else
      _ -> {:error, "downloaded file is not a gitf escript (no readable gitf.app inside)."}
    end
  end

  defp ensure_dot(tokens) do
    case List.last(tokens) do
      {:dot, _} -> tokens
      _ -> tokens ++ [{:dot, 1}]
    end
  end

  # Same-directory temp file + rename, so the swap is atomic and the
  # running escript (already fully read into memory) is never truncated.
  defp install(new_binary, target) do
    staged = target <> ".self-update"
    File.cp!(new_binary, staged)
    File.chmod!(staged, 0o755)
    File.rename!(staged, target)
  end
end
