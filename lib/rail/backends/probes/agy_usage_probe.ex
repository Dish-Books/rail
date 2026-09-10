defmodule Rail.Backends.Probes.AgyUsageProbe do
  @moduledoc """
  Probes local Antigravity CLI installation for auth status and quota usage.
  """

  alias Rail.Backends.Probes
  alias Rail.Backends.ProcessRunner
  alias Rail.ToolEnv

  @auth_regex ~r/applyAuthResult:\s*email=([^,]*),\s*authMethod=([^,\s]*)/

  @doc """
  Runs the full probe flow against Antigravity CLI.
  """
  def probe(opts \\ []) do
    executable =
      Keyword.get(opts, :executable_path) ||
        Keyword.get(opts, :executable) ||
        ToolEnv.find_executable("agy") ||
        "agy"

    path_validator = Keyword.get(opts, :path_validator, &Probes.default_path_validator/1)
    runner = Keyword.get(opts, :runner, &ProcessRunner.run/3)
    file_reader = Keyword.get(opts, :file_reader, &File.read/1)

    if path_validator.(executable) do
      run_probe_with_temp_dir(executable, runner, file_reader, opts)
    else
      not_configured_result(executable)
    end
  end

  @doc """
  Pure parser for Antigravity CLI usage JSON output and log file content.
  """
  def parse(_executable_path, opts \\ []) do
    usage_stdout = Keyword.get(opts, :usage_stdout, "")
    log_content = Keyword.get(opts, :log_content, "") || ""
    fetched_at = Keyword.get(opts, :fetched_at) || DateTime.utc_now()

    case Jason.decode(usage_stdout) do
      {:ok, json} ->
        status = json["status"]
        response = json["response"]

        if status == "SUCCESS" do
          parse_success(json, log_content, fetched_at)
        else
          handle_non_success_status(status, response)
        end

      {:error, error} ->
        unavailable_result("Failed to parse usage JSON: #{inspect(error)}")
    end
  end

  defp run_probe_with_temp_dir(executable, runner, file_reader, opts) do
    temp_dir =
      Keyword.get(opts, :temp_dir) ||
        Path.join(System.tmp_dir!(), "agy_usage_#{System.unique_integer([:positive])}")

    File.mkdir_p(temp_dir)
    scratch_log = Path.join(temp_dir, "agy_scratch.log")

    try do
      execute_agy_command(executable, runner, file_reader, scratch_log, temp_dir, opts)
    after
      cleanup_temp_dir(temp_dir, scratch_log)
    end
  end

  defp execute_agy_command(executable, runner, file_reader, scratch_log, temp_dir, opts) do
    args = ["-p", "/usage", "--output-format", "json", "--log-file", scratch_log]

    case run_command(runner, executable, args, 20_000, cd: temp_dir) do
      {:error, :timeout} ->
        unavailable_result("Usage check timed out after 20s")

      {:error, error} ->
        unavailable_result("Failed to execute probe: #{inspect(error)}")

      {:ok, stdout, exit_code} when exit_code != 0 ->
        if String.contains?(stdout, "NOT_LOGGED_IN") do
          signed_out_result("CLI exited with code #{exit_code}")
        else
          unavailable_result("CLI exited with code #{exit_code}")
        end

      {:ok, stdout, 0} ->
        log_content = read_scratch_log(file_reader, scratch_log)
        parse(executable, usage_stdout: stdout, log_content: log_content, fetched_at: opts[:fetched_at])
    end
  end

  defp read_scratch_log(file_reader, scratch_log) do
    case file_reader.(scratch_log) do
      {:ok, content} -> content
      _other -> ""
    end
  end

  defp cleanup_temp_dir(temp_dir, scratch_log) do
    _rm_file = File.rm(scratch_log)
    _rm_dir = File.rmdir(temp_dir)
    :ok
  end

  defp parse_success(json, log_content, fetched_at) do
    {account_label, account_detail} = scrape_identity(log_content)
    raw_groups = get_in(json, ["command", "data", "groups"]) || []
    groups = transform_groups(raw_groups)

    %{
      backend: :agy,
      status: "ready",
      account_label: account_label,
      account_detail: account_detail,
      groups: groups,
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

    probe_status = if logged_out?, do: "signed_out", else: "unavailable"
    reason = if is_binary(response) and response != "", do: response, else: status || "Unknown error"

    %{
      backend: :agy,
      status: probe_status,
      account_label: nil,
      account_detail: nil,
      groups: [],
      fetched_at: nil,
      unavailable_reason: reason
    }
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

      buckets = group["buckets"] || []
      windows = Enum.map(buckets, &transform_bucket/1)

      %{
        name: name,
        count: length(windows),
        details: %{"windows" => windows}
      }
    end)
  end

  defp transform_groups(_other), do: []

  defp transform_bucket(bucket) do
    window = bucket["window"]
    bucket_name = bucket["name"]

    label =
      cond do
        window == "5h" ->
          "5-Hour"

        window == "weekly" ->
          "Weekly"

        is_binary(bucket_name) and bucket_name != "" ->
          bucket_name

        is_binary(window) and window != "" ->
          window

        true ->
          "Limit"
      end

    remaining_percent =
      if is_number(bucket["remaining_fraction"]) do
        bucket["remaining_fraction"] * 100.0
      end

    %{
      "label" => label,
      "remaining_percent" => remaining_percent,
      "resets_at" => bucket["reset_time"],
      "unmeasured_reason" => nil
    }
  end

  defp run_command(runner, executable, args, timeout, opts) do
    opts = Keyword.put(opts, :timeout, timeout)
    executable |> runner.(args, opts) |> ProcessRunner.normalize_result()
  end

  defp not_configured_result(executable) do
    %{
      backend: :agy,
      status: "not_configured",
      account_label: nil,
      account_detail: nil,
      groups: [],
      fetched_at: nil,
      unavailable_reason: "Executable not found at '#{executable}'"
    }
  end

  defp signed_out_result(reason) do
    %{
      backend: :agy,
      status: "signed_out",
      account_label: nil,
      account_detail: nil,
      groups: [],
      fetched_at: nil,
      unavailable_reason: reason
    }
  end

  defp unavailable_result(reason) do
    %{
      backend: :agy,
      status: "unavailable",
      account_label: nil,
      account_detail: nil,
      groups: [],
      fetched_at: nil,
      unavailable_reason: reason
    }
  end
end
