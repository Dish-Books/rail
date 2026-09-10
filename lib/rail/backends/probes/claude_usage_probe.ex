defmodule Rail.Backends.Probes.ClaudeUsageProbe do
  @moduledoc """
  Probes local Claude Code CLI installation for auth status and quota usage.
  """

  alias Rail.Backends.Probes
  alias Rail.Backends.ProcessRunner

  @doc """
  Runs the full probe flow against Claude Code CLI.
  """
  def probe(opts \\ []) do
    executable =
      Keyword.get(opts, :executable_path) ||
        Keyword.get(opts, :executable) ||
        Probes.configured_path(:claude)

    path_validator = Keyword.get(opts, :path_validator, &Probes.default_path_validator/1)
    runner = Keyword.get(opts, :runner, &ProcessRunner.run/3)
    config_file_reader = Keyword.get(opts, :config_file_reader, &Probes.default_config_file_reader/1)

    if path_validator.(executable) do
      check_auth_and_read_usage(executable, runner, config_file_reader, opts)
    else
      not_configured_result(executable)
    end
  end

  @doc """
  Pure parser for Claude Code auth status and configuration content.
  """
  def parse(_executable_path, auth_stdout, config_content) do
    case Jason.decode(auth_stdout) do
      {:ok, auth_data} ->
        logged_in = auth_data["loggedIn"] == true
        email = auth_data["email"]
        subscription = auth_data["subscriptionType"]

        if logged_in do
          parse_config(config_content, email, subscription)
        else
          signed_out_result(email, subscription)
        end

      {:error, error} ->
        unavailable_result("Failed to parse auth status JSON: #{inspect(error)}")
    end
  end

  defp check_auth_and_read_usage(executable, runner, config_file_reader, opts) do
    case run_command(runner, executable, ["auth", "status", "--json"], 20_000) do
      {:error, :timeout} ->
        unavailable_result("Auth status timed out after 20s")

      {:error, error} ->
        unavailable_result("Failed to run auth status: #{inspect(error)}")

      {:ok, _stdout, exit_code} when exit_code != 0 ->
        unavailable_result("Auth status exited with code #{exit_code}")

      {:ok, stdout, 0} ->
        handle_auth_success(executable, stdout, runner, config_file_reader, opts)
    end
  end

  defp handle_auth_success(executable, auth_stdout, runner, config_file_reader, opts) do
    case Jason.decode(auth_stdout) do
      {:ok, %{"loggedIn" => true} = auth_data} ->
        email = auth_data["email"]
        subscription = auth_data["subscriptionType"]
        refresh_quota_cache(executable, runner)
        read_and_parse_config(executable, auth_stdout, email, subscription, config_file_reader, opts)

      {:ok, auth_data} ->
        email = auth_data["email"]
        subscription = auth_data["subscriptionType"]
        signed_out_result(email, subscription)

      {:error, error} ->
        unavailable_result("Failed to parse auth status JSON: #{inspect(error)}")
    end
  end

  defp refresh_quota_cache(executable, runner) do
    temp_dir = Path.join(System.tmp_dir!(), "rail_claude_usage")
    File.mkdir_p(temp_dir)

    try do
      run_command(runner, executable, ["-p", "/usage", "--output-format", "json"], 20_000, cd: temp_dir)
    rescue
      _error -> :ok
    end
  end

  defp read_and_parse_config(executable, auth_stdout, email, subscription, config_file_reader, opts) do
    case resolve_config_path(opts) do
      {:ok, config_path} ->
        case config_file_reader.(config_path) do
          {:ok, config_content} ->
            parse(executable, auth_stdout, config_content)

          {:error, error} ->
            unavailable_result(
              "Failed to read Claude config at '#{config_path}': #{inspect(error)}",
              email,
              subscription
            )
        end

      {:error, reason} ->
        unavailable_result(reason, email, subscription)
    end
  end

  defp resolve_config_path(opts) do
    custom_path = Keyword.get(opts, :custom_config_path)
    claude_dir = System.get_env("CLAUDE_CONFIG_DIR")
    home_dir = System.get_env("HOME")

    cond do
      is_binary(custom_path) and custom_path != "" ->
        {:ok, custom_path}

      is_binary(claude_dir) and claude_dir != "" ->
        {:ok, Path.join(claude_dir, ".claude.json")}

      is_binary(home_dir) and home_dir != "" ->
        {:ok, Path.join(home_dir, ".claude.json")}

      true ->
        {:error, "Could not determine user home or config directory"}
    end
  end

  defp parse_config(config_content, email, subscription) do
    case Jason.decode(config_content) do
      {:ok, %{"cachedUsageUtilization" => cached}} when is_map(cached) ->
        fetched_at =
          if is_integer(cached["fetchedAtMs"]) do
            DateTime.from_unix!(cached["fetchedAtMs"], :millisecond)
          else
            DateTime.utc_now()
          end

        limits = get_in(cached, ["utilization", "limits"]) || []
        groups = transform_limits(limits)

        %{
          backend: :claude,
          status: "ready",
          account_label: email,
          account_detail: subscription,
          groups: groups,
          fetched_at: fetched_at,
          unavailable_reason: nil
        }

      {:ok, _config_json} ->
        unavailable_result("No cachedUsageUtilization found in config", email, subscription)

      {:error, error} ->
        unavailable_result("Failed to parse config file: #{inspect(error)}", email, subscription)
    end
  end

  defp transform_limits(limits) when is_list(limits) do
    {ordered_keys, grouped_map} =
      Enum.reduce(limits, {[], %{}}, fn item, {order, acc} ->
        group_name = format_group_name(item["group"])
        window = format_window(item)

        case Map.fetch(acc, group_name) do
          {:ok, windows} ->
            {order, Map.put(acc, group_name, [window | windows])}

          :error ->
            {[group_name | order], Map.put(acc, group_name, [window])}
        end
      end)

    ordered_keys
    |> Enum.reverse()
    |> Enum.map(fn name ->
      windows = grouped_map |> Map.get(name, []) |> Enum.reverse()

      %{
        name: name,
        count: length(windows),
        details: %{"windows" => windows}
      }
    end)
  end

  defp transform_limits(_other), do: []

  defp format_group_name(nil), do: "General"
  defp format_group_name(""), do: "General"
  defp format_group_name("session"), do: "Session"
  defp format_group_name("weekly"), do: "Weekly"
  defp format_group_name(other) when is_binary(other), do: String.capitalize(other)

  defp format_window(item) do
    model_display = get_in(item, ["scope", "model", "display_name"])
    kind = item["kind"]

    label =
      cond do
        is_binary(model_display) and model_display != "" ->
          "Weekly · #{model_display}"

        kind == "session" ->
          "Session"

        kind == "weekly_all" ->
          "Weekly (all models)"

        is_binary(kind) and kind != "" ->
          kind

        true ->
          "Window"
      end

    remaining_percent =
      if is_number(item["percent"]) do
        100.0 - item["percent"]
      end

    %{
      "label" => label,
      "remaining_percent" => remaining_percent,
      "resets_at" => item["resets_at"],
      "unmeasured_reason" => nil
    }
  end

  defp run_command(runner, executable, args, timeout, opts \\ []) do
    opts = Keyword.put(opts, :timeout, timeout)
    executable |> runner.(args, opts) |> ProcessRunner.normalize_result()
  end

  defp not_configured_result(executable) do
    %{
      backend: :claude,
      status: "not_configured",
      account_label: nil,
      account_detail: nil,
      groups: [],
      fetched_at: nil,
      unavailable_reason: "Executable not found at '#{executable}'"
    }
  end

  defp signed_out_result(email, subscription) do
    %{
      backend: :claude,
      status: "signed_out",
      account_label: email,
      account_detail: subscription,
      groups: [],
      fetched_at: nil,
      unavailable_reason: "Not logged in"
    }
  end

  defp unavailable_result(reason, email \\ nil, subscription \\ nil) do
    %{
      backend: :claude,
      status: "unavailable",
      account_label: email,
      account_detail: subscription,
      groups: [],
      fetched_at: nil,
      unavailable_reason: reason
    }
  end
end
