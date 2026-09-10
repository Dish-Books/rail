defmodule RailWeb.CliAccountsLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Backends
  alias Rail.Domain.Embeds.CliAccountGroup

  def mount(_params, _session, socket) do
    accounts = Backends.list_accounts()
    now = DateTime.utc_now()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "backends:usage_updated")
      :timer.send_interval(30_000, self(), :tick)
    end

    socket =
      socket
      |> assign(:page_title, "CLI Accounts")
      |> assign(:current_section, :cli_accounts)
      |> assign(:current_project_id, nil)
      |> assign(:accounts, accounts)
      |> assign(:is_refreshing, false)
      |> assign(:now, now)

    {:ok, socket}
  end

  def handle_params(params, _uri, socket) do
    project_id =
      case Map.get(params, "project") do
        id when is_binary(id) and id != "" -> id
        _other -> nil
      end

    socket =
      socket
      |> assign(:page_title, "CLI Accounts")
      |> assign(:current_section, :cli_accounts)
      |> assign(:current_project_id, project_id)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div
      id="cli-accounts-view"
      data-qa="cli-accounts-view"
      class="max-w-5xl mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-8"
    >
      <!-- Header Row -->
      <div
        class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4"
        id="cli-accounts-header"
      >
        <div>
          <h1
            class="text-2xl font-bold tracking-tight text-zinc-900"
            id="cli-accounts-title"
            data-qa="cli_accounts_title"
          >
            CLI Accounts
          </h1>
          <p class="mt-1 text-sm text-zinc-500" id="cli-accounts-subtitle">
            Account identities • Rolling usage windows • Local reset times
          </p>
        </div>

        <div>
          <button
            type="button"
            phx-click="refresh_quotas"
            id="refresh-quotas-button"
            data-qa="refresh_quotas_button"
            disabled={@is_refreshing}
            class="inline-flex items-center gap-2 rounded-md bg-white px-3.5 py-2 text-sm font-semibold text-zinc-700 shadow-xs ring-1 ring-inset ring-zinc-300 hover:bg-zinc-50 disabled:opacity-50 transition-colors"
          >
            <.icon
              :if={not @is_refreshing}
              name="arrow_path"
              class="h-4 w-4 text-zinc-500"
            />
            <.icon
              :if={@is_refreshing}
              name="arrow_path"
              class="h-4 w-4 text-zinc-500 animate-spin"
            />
            <span>Refresh Quotas</span>
          </button>
        </div>
      </div>

      <!-- State: Loading initial accounts -->
      <div
        :if={Enum.empty?(@accounts) and @is_refreshing}
        id="cli-accounts-loading"
        data-qa="cli_accounts_loading"
        class="p-12 text-center bg-white rounded-lg border border-zinc-200"
      >
        <.icon name="arrow_path" class="h-8 w-8 text-indigo-600 animate-spin mx-auto mb-3" />
        <p class="text-sm font-medium text-zinc-600">Probing CLI account quotas...</p>
      </div>

      <!-- State: Empty accounts, not refreshing -->
      <div
        :if={Enum.empty?(@accounts) and not @is_refreshing}
        id="cli-accounts-empty"
        data-qa="cli_accounts_empty"
        class="p-12 text-center bg-white rounded-lg border border-zinc-200"
      >
        <.icon name="cpu_chip" class="h-10 w-10 text-zinc-400 mx-auto mb-3" />
        <p class="text-sm text-zinc-500">
          No CLI accounts checked yet. Click Refresh Quotas to probe.
        </p>
      </div>

      <!-- State: Populated accounts list -->
      <div
        :if={not Enum.empty?(@accounts)}
        id="cli-accounts-list"
        data-qa="cli_accounts_list"
        class="space-y-6"
      >
        <div
          :for={account <- @accounts}
          id={"backend-card-#{account.backend}"}
          data-qa={"cli-account-row backend_card_#{account.backend}"}
          class="bg-white shadow-xs rounded-xl border border-zinc-200 p-6 space-y-5"
        >
          <!-- Backend Card Header -->
          <div
            class="flex flex-wrap items-center justify-between gap-3"
            id={"backend-header-#{account.backend}"}
          >
            <div class="flex items-center gap-3 min-w-0">
              <div class="flex items-center justify-center h-10 w-10 rounded-lg bg-indigo-50 text-indigo-600 shrink-0">
                <.icon name={backend_icon(account.backend)} class="h-6 w-6" />
              </div>

              <div class="flex flex-wrap items-center gap-2 min-w-0">
                <span class="text-base font-bold text-zinc-900" id={"backend-name-#{account.backend}"}>
                  {display_name(account.backend)}
                </span>

                <span
                  :if={account.account_label not in [nil, ""]}
                  class="text-sm text-zinc-600 truncate max-w-xs"
                  id={"account-label-#{account.backend}"}
                >
                  {account.account_label}
                </span>

                <span
                  :if={account.account_detail not in [nil, ""]}
                  class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-bold uppercase tracking-wider bg-zinc-100 text-zinc-700 ring-1 ring-inset ring-zinc-200"
                  id={"account-detail-#{account.backend}"}
                >
                  {String.upcase(account.account_detail)}
                </span>

                <% badge = status_badge(account.status) %>
                <span
                  class={"inline-flex items-center px-2 py-0.5 rounded text-xs font-semibold #{badge.class}"}
                  id={"status-badge-#{account.backend}"}
                >
                  {badge.label}
                </span>
              </div>
            </div>

            <div
              :if={not is_nil(account.fetched_at)}
              class="flex items-center gap-1.5 text-xs text-zinc-400 shrink-0"
              id={"fetched-at-#{account.backend}"}
            >
              <.icon name="clock" class="h-3.5 w-3.5" />
              <span>read {format_age(account.fetched_at, @now)}</span>
            </div>
          </div>

          <!-- Backend Card Body -->
          <!-- Not Configured Banner -->
          <div
            :if={account.status == "not_configured"}
            id={"banner-not-configured-#{account.backend}"}
            class="flex items-start gap-3 p-4 rounded-lg bg-zinc-100 border border-zinc-200 text-zinc-700 text-xs"
          >
            <.icon name="exclamation_triangle" class="h-5 w-5 text-zinc-500 shrink-0 mt-0.5" />
            <div>
              <p class="font-medium">Backend Not Configured</p>
              <p class="mt-0.5 text-zinc-500">
                {account.unavailable_reason ||
                  "Executable not found or not executable. Check path in Settings."}
              </p>
            </div>
          </div>

          <!-- Signed Out Banner -->
          <div
            :if={account.status == "signed_out"}
            id={"banner-signed-out-#{account.backend}"}
            class="flex items-start gap-3 p-4 rounded-lg bg-amber-50 border border-amber-300 text-amber-900 text-xs"
          >
            <.icon name="lock_closed" class="h-5 w-5 text-amber-700 shrink-0 mt-0.5" />
            <div>
              <p class="font-medium">Signed Out</p>
              <p class="mt-0.5 text-amber-800">
                {account.unavailable_reason ||
                  "CLI is signed out. Log in to your account via the command line to view usage limits."}
              </p>
            </div>
          </div>

          <!-- Unavailable Banner -->
          <div
            :if={account.status == "unavailable"}
            id={"banner-unavailable-#{account.backend}"}
            class="flex items-start gap-3 p-4 rounded-lg bg-red-50 border border-red-200 text-red-900 text-xs"
          >
            <.icon name="exclamation_circle" class="h-5 w-5 text-red-600 shrink-0 mt-0.5" />
            <div>
              <p class="font-medium">Service Unavailable</p>
              <p class="mt-0.5 text-red-700">
                {account.unavailable_reason || "Failed to fetch usage data from backend CLI."}
              </p>
            </div>
          </div>

          <!-- Empty Quota Windows in Ready Status -->
          <div
            :if={
              account.status == "ready" and (is_nil(account.groups) or Enum.empty?(account.groups))
            }
            id={"no-quota-windows-#{account.backend}"}
            class="py-3 text-sm text-zinc-400 italic"
          >
            No quota windows reported for this account.
          </div>

          <!-- Usage Groups Sections -->
          <div
            :if={
              account.status == "ready" and not is_nil(account.groups) and
                not Enum.empty?(account.groups)
            }
            class="space-y-4"
            id={"groups-container-#{account.backend}"}
          >
            <div
              :for={{group, g_idx} <- Enum.with_index(account.groups || [])}
              id={"group-section-#{account.backend}-#{g_idx}"}
              class="rounded-lg bg-zinc-50 border border-zinc-200 p-4 space-y-3"
            >
              <h3
                class="text-xs font-bold uppercase tracking-wider text-indigo-700"
                id={"group-name-#{account.backend}-#{g_idx}"}
              >
                {group.name}
              </h3>

              <% windows = extract_windows(group) %>
              <div class="divide-y divide-zinc-200/70" id={"windows-list-#{account.backend}-#{g_idx}"}>
                <div
                  :for={{window, w_idx} <- Enum.with_index(windows)}
                  id={"window-row-#{account.backend}-#{g_idx}-#{w_idx}"}
                  class="py-2.5 first:pt-0 last:pb-0"
                >
                  <div class="flex items-center justify-between text-xs">
                    <span
                      class="font-medium text-zinc-800"
                      id={"window-label-#{account.backend}-#{g_idx}-#{w_idx}"}
                    >
                      {window["label"]}
                    </span>

                    <div class="flex items-center gap-3">
                      <span
                        class={"font-semibold #{text_color_class(window["remaining_percent"])}"}
                        id={"window-remaining-#{account.backend}-#{g_idx}-#{w_idx}"}
                      >
                        {format_remaining(window["remaining_percent"], window["unmeasured_reason"])}
                      </span>

                      <span
                        class="text-zinc-400"
                        id={"window-reset-#{account.backend}-#{g_idx}-#{w_idx}"}
                      >
                        {format_reset_string(window["resets_at"], @now)}
                      </span>
                    </div>
                  </div>

                  <!-- Critical parity rule: Progress bar rendered ONLY when remaining_percent is not nil -->
                  <div
                    :if={not is_nil(window["remaining_percent"])}
                    id={"progress-bar-#{account.backend}-#{g_idx}-#{w_idx}"}
                    class="mt-2 w-full bg-zinc-200 rounded-full h-1.5 overflow-hidden"
                  >
                    <div
                      class={"h-1.5 rounded-full #{bar_color_class(window["remaining_percent"])}"}
                      style={"width: #{clamp_percent(window["remaining_percent"])}%"}
                    >
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  def handle_event("refresh_quotas", _params, socket) do
    if socket.assigns.is_refreshing do
      {:noreply, socket}
    else
      socket =
        socket
        |> assign(:is_refreshing, true)
        |> start_async(:refresh_quotas_task, fn ->
          Backends.refresh_usage()
        end)

      {:noreply, socket}
    end
  end

  def handle_info({:usage_updated, accounts}, socket) do
    socket =
      socket
      |> assign(:accounts, accounts)
      |> assign(:is_refreshing, false)
      |> assign(:now, DateTime.utc_now())

    {:noreply, socket}
  end

  def handle_info(:tick, socket) do
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_async(:refresh_quotas_task, {:ok, {:ok, accounts}}, socket) do
    socket =
      socket
      |> assign(:accounts, accounts)
      |> assign(:is_refreshing, false)
      |> assign(:now, DateTime.utc_now())

    {:noreply, socket}
  end

  def handle_async(:refresh_quotas_task, _result, socket) do
    {:noreply, assign(socket, :is_refreshing, false)}
  end

  defp display_name(:claude), do: "Claude Code"
  defp display_name(:agy), do: "Antigravity CLI"
  defp display_name(other), do: other |> to_string() |> String.capitalize()

  defp backend_icon(:claude), do: "terminal"
  defp backend_icon(:agy), do: "rocket_launch"
  defp backend_icon(_other), do: "cpu_chip"

  defp status_badge("ready") do
    %{label: "Active", class: "bg-emerald-100 text-emerald-900 ring-1 ring-inset ring-emerald-200"}
  end

  defp status_badge("signed_out") do
    %{label: "Signed Out", class: "bg-amber-100 text-amber-900 ring-1 ring-inset ring-amber-200"}
  end

  defp status_badge("unavailable") do
    %{label: "Unavailable", class: "bg-red-100 text-red-900 ring-1 ring-inset ring-red-200"}
  end

  defp status_badge("not_configured") do
    %{label: "Not Configured", class: "bg-zinc-200 text-zinc-800 ring-1 ring-inset ring-zinc-300"}
  end

  defp status_badge(other) do
    label = other |> to_string() |> String.capitalize()
    %{label: label, class: "bg-zinc-100 text-zinc-700 ring-1 ring-inset ring-zinc-300"}
  end

  defp format_age(%DateTime{} = fetched_at, %DateTime{} = now) do
    diff_s = DateTime.diff(now, fetched_at, :second)

    cond do
      diff_s < 60 -> "just now"
      diff_s < 3600 -> "#{div(diff_s, 60)}m ago"
      diff_s < 86_400 -> "#{div(diff_s, 3600)}h ago"
      true -> "#{div(diff_s, 86_400)}d ago"
    end
  end

  defp format_remaining(remaining_percent, unmeasured_reason) do
    cond do
      is_number(remaining_percent) ->
        formatted =
          if remaining_percent == trunc(remaining_percent) do
            "#{trunc(remaining_percent)}"
          else
            :erlang.float_to_binary(remaining_percent / 1.0, decimals: 1)
          end

        "#{formatted}% remaining"

      is_binary(unmeasured_reason) and unmeasured_reason != "" ->
        unmeasured_reason

      true ->
        "Limit unmeasured"
    end
  end

  defp bar_color_class(remaining_percent) do
    cond do
      remaining_percent >= 30.0 -> "bg-emerald-600"
      remaining_percent >= 10.0 -> "bg-amber-600"
      true -> "bg-red-600"
    end
  end

  defp text_color_class(remaining_percent) do
    cond do
      is_nil(remaining_percent) -> "text-zinc-400"
      remaining_percent >= 30.0 -> "text-emerald-700"
      remaining_percent >= 10.0 -> "text-amber-700"
      true -> "text-red-700"
    end
  end

  defp format_reset_string(resets_at, now) do
    case parse_datetime(resets_at) do
      %DateTime{} = dt ->
        "Resets #{format_reset_local(dt, now)}"

      nil ->
        "Reset time unknown"
    end
  end

  defp format_reset_local(%DateTime{} = dt, %DateTime{} = now) do
    hour = dt.hour
    ampm = if hour >= 12, do: "PM", else: "AM"
    h12 = rem(hour, 12)
    h12 = if h12 == 0, do: 12, else: h12
    minute_str = dt.minute |> to_string() |> String.pad_leading(2, "0")
    time_str = "#{h12}:#{minute_str} #{ampm}"

    now_date = DateTime.to_date(now)
    reset_date = DateTime.to_date(dt)
    diff_days = Date.diff(reset_date, now_date)

    case diff_days do
      0 ->
        "today #{time_str}"

      1 ->
        "tomorrow #{time_str}"

      _other ->
        date_str = Calendar.strftime(dt, "%a %b %-d")
        "#{date_str}, #{time_str}"
    end
  end

  defp extract_windows(%CliAccountGroup{details: details}) when is_map(details) do
    cond do
      is_list(details["windows"]) -> details["windows"]
      is_number(details["remaining_percent"]) -> [details]
      true -> []
    end
  end

  defp extract_windows(_group), do: []

  defp clamp_percent(val) when is_number(val) do
    val
    |> max(0.0)
    |> min(100.0)
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt
  defp parse_datetime(ts) when is_float(ts), do: parse_datetime(trunc(ts))

  defp parse_datetime(ts) when is_integer(ts) do
    unit = if ts > 10_000_000_000, do: :millisecond, else: :second

    case DateTime.from_unix(ts, unit) do
      {:ok, dt} -> dt
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} ->
        dt

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(str) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          {:error, _err} -> nil
        end
    end
  end

  defp parse_datetime(_raw), do: nil
end
