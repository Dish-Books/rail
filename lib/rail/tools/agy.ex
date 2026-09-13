defmodule Rail.Tools.Agy do
  @moduledoc """
  Drives the local Antigravity CLI: asks it for quota usage and scrapes the
  account it logged, as the fields a `Rail.Tools.Schemas.Backend` records.
  """

  import Rail.Tools.Utils.BackendEnv

  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  @auth_regex ~r/applyAuthResult:\s*email=([^,]*),\s*authMethod=([^,\s]*)/
  @timeout 20_000

  @doc """
  Probes the CLI at the backend's configured path.

  Returns the usage fields for `Backend.usage_changeset/2`. Every failure is
  reported as a status rather than raised, so one broken CLI cannot fail a
  refresh of the others.
  """
  def probe(%Backend{} = backend) do
    executable = backend.executable_path || ""

    if executable_file?(executable) do
      run_in_temp_dir(backend, executable)
    else
      not_configured_result(executable)
    end
  end

  defp parse(usage_stdout, log_content) do
    case Jason.decode(usage_stdout) do
      {:ok, %{"status" => "SUCCESS"} = json} ->
        parse_success(json, log_content, DateTime.utc_now())

      {:ok, json} ->
        handle_non_success_status(json["status"], json["response"])

      {:error, error} ->
        unavailable_result("Failed to parse usage JSON: #{inspect(error)}")
    end
  end

  # A path is only worth running if it is a regular file with an execute bit.
  defp executable_file?(path) when is_binary(path) and path != "" do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp executable_file?(_other), do: false

  # The CLI only names the signed-in account in its log, so it is given a
  # scratch one per probe and the directory is cleaned up afterwards.
  defp run_in_temp_dir(backend, executable) do
    temp_dir = Path.join(System.tmp_dir!(), "agy_usage_#{System.unique_integer([:positive])}")
    File.mkdir_p(temp_dir)
    scratch_log = Path.join(temp_dir, "agy_scratch.log")

    try do
      run_usage(backend, executable, scratch_log, temp_dir)
    after
      _rm_file = File.rm(scratch_log)
      _rm_dir = File.rmdir(temp_dir)
    end
  end

  defp run_usage(backend, executable, scratch_log, temp_dir) do
    args = ["-p", "/usage", "--output-format", "json", "--log-file", scratch_log]

    case Tools.run(executable, args, timeout: @timeout, cd: temp_dir, env: backend_env(backend)) do
      {:error, :timeout} ->
        unavailable_result("Usage check timed out after 20s")

      {:error, error} ->
        unavailable_result("Failed to execute probe: #{inspect(error)}")

      {stdout, exit_code} when is_binary(stdout) and exit_code != 0 ->
        if String.contains?(stdout, "NOT_LOGGED_IN") do
          signed_out_result("CLI exited with code #{exit_code}")
        else
          unavailable_result("CLI exited with code #{exit_code}")
        end

      {stdout, 0} when is_binary(stdout) ->
        log_content =
          case File.read(scratch_log) do
            {:ok, content} -> content
            _unreadable -> ""
          end

        parse(stdout, log_content)
    end
  end

  defp parse_success(json, log_content, fetched_at) do
    {account_label, account_detail} = scrape_identity(log_content)

    %{
      name: :agy,
      status: :ready,
      account_label: account_label,
      account_detail: account_detail,
      usage: transform_groups(get_in(json, ["command", "data", "groups"]) || []),
      fetched_at: fetched_at,
      unavailable_reason: nil
    }
  end

  defp handle_non_success_status(status, response) do
    logged_out? =
      status == "NOT_LOGGED_IN" or
        (is_binary(response) and
           (String.contains?(String.downcase(response), "log in") or
              String.contains?(String.downcase(response), "not logged in")))

    reason = if is_binary(response) and response != "", do: response, else: status || "Unknown error"

    if logged_out? do
      signed_out_result(reason)
    else
      unavailable_result(reason)
    end
  end

  defp scrape_identity(log_content) when is_binary(log_content) do
    case Regex.run(@auth_regex, log_content) do
      [_full_match, email, auth_method] ->
        trimmed_email = String.trim(email)
        trimmed_method = String.trim(auth_method)

        account_label = if trimmed_email == "", do: "Account unknown", else: trimmed_email
        account_detail = if trimmed_method == "", do: nil, else: trimmed_method

        {account_label, account_detail}

      _other ->
        {"Account unknown", nil}
    end
  end

  defp transform_groups(raw_groups) when is_list(raw_groups) do
    Enum.map(raw_groups, fn group ->
      name =
        case group["name"] do
          str when is_binary(str) and str != "" -> str
          _other -> "Limits"
        end

      windows = group |> Map.get("buckets", []) |> List.wrap() |> Enum.map(&transform_bucket/1)

      %{name: name, count: length(windows), details: %{"windows" => windows}}
    end)
  end

  defp transform_groups(_other), do: []

  defp transform_bucket(bucket) do
    window = bucket["window"]
    bucket_name = bucket["name"]

    label =
      cond do
        window == "5h" -> "5-Hour"
        window == "weekly" -> "Weekly"
        is_binary(bucket_name) and bucket_name != "" -> bucket_name
        is_binary(window) and window != "" -> window
        true -> "Limit"
      end

    remaining_percent = if is_number(bucket["remaining_fraction"]), do: bucket["remaining_fraction"] * 100.0

    %{
      "label" => label,
      "remaining_percent" => remaining_percent,
      "resets_at" => bucket["reset_time"],
      "unmeasured_reason" => nil
    }
  end

  defp not_configured_result(executable) do
    result(:not_configured, "Executable not found at '#{executable}'")
  end

  defp signed_out_result(reason), do: result(:signed_out, reason)
  defp unavailable_result(reason), do: result(:unavailable, reason)

  defp result(status, reason) do
    %{
      name: :agy,
      status: status,
      account_label: nil,
      account_detail: nil,
      usage: [],
      fetched_at: nil,
      unavailable_reason: reason
    }
  end
end
