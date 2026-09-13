defmodule Rail.Tools.Claude do
  @moduledoc """
  Drives the local Claude Code CLI: asks it who is signed in and reads the
  quota usage it caches, as the fields a `Rail.Tools.Schemas.Backend` records.
  """

  import Rail.Tools.Utils.BackendEnv

  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  @timeout 20_000
  # `claude -p` waits on a stdin that is not a terminal in case something is
  # piped in, and System.cmd leaves stdin an open pipe; /dev/null says nothing is.
  @without_stdin ~s(exec "$0" "$@" </dev/null)

  @doc """
  Probes the CLI at the backend's configured path, signed in to the account in
  the backend's config directory.

  Returns the usage fields for `Backend.usage_changeset/2`. Every failure is
  reported as a status rather than raised, so one broken CLI cannot fail a
  refresh of the others.
  """
  def probe(%Backend{} = backend) do
    executable = backend.executable_path || ""

    if executable_file?(executable) do
      check_auth(backend, executable)
    else
      not_configured_result(executable)
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

  defp check_auth(backend, executable) do
    case Tools.run(executable, ["auth", "status", "--json"], timeout: @timeout, env: backend_env(backend)) do
      {:error, :timeout} ->
        unavailable_result("Auth status timed out after 20s")

      {:error, error} ->
        unavailable_result("Failed to run auth status: #{inspect(error)}")

      {_stdout, exit_code} when is_integer(exit_code) and exit_code != 0 ->
        unavailable_result("Auth status exited with code #{exit_code}")

      {stdout, 0} when is_binary(stdout) ->
        handle_auth_success(backend, executable, stdout)
    end
  end

  defp handle_auth_success(backend, executable, auth_stdout) do
    case Jason.decode(auth_stdout) do
      {:ok, %{"loggedIn" => true} = auth_data} ->
        email = auth_data["email"]
        subscription = auth_data["subscriptionType"]
        refresh_quota_cache(backend, executable)
        read_config(backend, email, subscription)

      {:ok, auth_data} ->
        signed_out_result(auth_data["email"], auth_data["subscriptionType"])

      {:error, error} ->
        unavailable_result("Failed to parse auth status JSON: #{inspect(error)}")
    end
  end

  # The CLI only writes usage into its config as a side effect of being asked
  # for it, so the cache has to be warmed before the config is worth reading.
  defp refresh_quota_cache(backend, executable) do
    temp_dir = Path.join(System.tmp_dir!(), "rail_claude_usage")
    File.mkdir_p(temp_dir)

    try do
      Tools.run("/bin/sh", ["-c", @without_stdin, executable, "-p", "/usage", "--output-format", "json"],
        timeout: @timeout,
        cd: temp_dir,
        env: backend_env(backend),
        stderr_to_stdout: true
      )
    rescue
      _error -> :ok
    end
  end

  defp read_config(backend, email, subscription) do
    config_path = config_path(backend)

    case File.read(config_path) do
      {:ok, config_content} ->
        parse_config(config_content, email, subscription)

      {:error, error} ->
        unavailable_result("Failed to read Claude config at '#{config_path}': #{inspect(error)}", email, subscription)
    end
  end

  defp config_path(backend), do: Path.join(Backend.config_dir(backend), ".claude.json")

  defp parse_config(config_content, email, subscription) do
    case Jason.decode(config_content) do
      {:ok, %{"cachedUsageUtilization" => cached}} when is_map(cached) ->
        fetched_at =
          if is_integer(cached["fetchedAtMs"]) do
            DateTime.from_unix!(cached["fetchedAtMs"], :millisecond)
          else
            DateTime.utc_now()
          end

        %{
          name: :claude,
          status: :ready,
          account_label: email,
          account_detail: subscription,
          usage: transform_limits(get_in(cached, ["utilization", "limits"]) || []),
          fetched_at: fetched_at,
          unavailable_reason: nil
        }

      {:ok, _config_json} ->
        unavailable_result("No cachedUsageUtilization found in config", email, subscription)

      {:error, error} ->
        unavailable_result("Failed to parse config file: #{inspect(error)}", email, subscription)
    end
  end

  # Limits arrive flat; the UI groups them, and the order the CLI reported them
  # in is the order they read best in.
  defp transform_limits(limits) when is_list(limits) do
    {ordered_keys, grouped_map} =
      Enum.reduce(limits, {[], %{}}, fn item, {order, acc} ->
        group_name = format_group_name(item["group"])
        window = format_window(item)

        case Map.fetch(acc, group_name) do
          {:ok, windows} -> {order, Map.put(acc, group_name, [window | windows])}
          :error -> {[group_name | order], Map.put(acc, group_name, [window])}
        end
      end)

    ordered_keys
    |> Enum.reverse()
    |> Enum.map(fn name ->
      windows = grouped_map |> Map.get(name, []) |> Enum.reverse()
      %{name: name, count: length(windows), details: %{"windows" => windows}}
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
        is_binary(model_display) and model_display != "" -> "Weekly · #{model_display}"
        kind == "session" -> "Session"
        kind == "weekly_all" -> "Weekly"
        is_binary(kind) and kind != "" -> kind
        true -> "Window"
      end

    remaining_percent = if is_number(item["percent"]), do: 100.0 - item["percent"]

    %{
      "label" => label,
      "remaining_percent" => remaining_percent,
      "resets_at" => item["resets_at"],
      "unmeasured_reason" => nil
    }
  end

  defp not_configured_result(executable) do
    result(:not_configured, "Executable not found at '#{executable}'")
  end

  defp signed_out_result(email, subscription) do
    :signed_out
    |> result("Not logged in")
    |> Map.merge(%{account_label: email, account_detail: subscription})
  end

  defp unavailable_result(reason, email \\ nil, subscription \\ nil) do
    :unavailable
    |> result(reason)
    |> Map.merge(%{account_label: email, account_detail: subscription})
  end

  defp result(status, reason) do
    %{
      name: :claude,
      status: status,
      account_label: nil,
      account_detail: nil,
      usage: [],
      fetched_at: nil,
      unavailable_reason: reason
    }
  end
end
