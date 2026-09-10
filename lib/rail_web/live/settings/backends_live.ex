defmodule RailWeb.Settings.BackendsLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Backends
  alias Rail.Backends.Schemas.Backend
  alias Rail.Domain.Embeds.CliAccountGroup

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Rail.PubSub, "backends:usage_updated")
      :timer.send_interval(30_000, self(), :tick)
    end

    socket =
      socket
      |> assign(:page_title, "Backends")
      |> assign(:current_section, :backends)
      |> assign(:accounts, Backends.list_accounts())
      |> assign(:is_refreshing, false)
      |> assign(:now, DateTime.utc_now())
      |> assign(:saved_backend, nil)
      |> assign(:save_error, nil)
      |> load_drafts()

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket) do
    socket =
      socket
      |> assign(:page_title, "Backends")
      |> assign(:current_section, :backends)

    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10" id="backends-settings">
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
        <div>
          <h1
            class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100"
            id="backends-title"
            data-qa="backends_title"
          >
            Backends
          </h1>
          <p class="mt-1 text-sm text-slate-500 dark:text-slate-400" id="backends-subtitle">
            CLI executable paths • Selectable models • Account usage windows
          </p>
        </div>

        <button
          type="button"
          phx-click="refresh_quotas"
          id="refresh-quotas-button"
          data-qa="refresh_quotas_button"
          disabled={@is_refreshing}
          class="inline-flex items-center gap-2 rounded-md bg-slate-50 dark:bg-slate-800 px-3.5 py-2 text-sm font-semibold text-slate-900 dark:text-slate-100 shadow-xs ring-1 ring-inset ring-slate-200 dark:ring-slate-700 hover:bg-slate-100 dark:hover:bg-slate-700 disabled:opacity-50 transition-colors"
        >
          <.icon
            name="pi-arrows-clockwise"
            class={[
              "h-4 w-4 text-slate-500 dark:text-slate-400",
              @is_refreshing && "animate-spin"
            ]}
          />
          <span>Refresh Quotas</span>
        </button>
      </div>

      <.settings_nav current_scope={@current_scope} active_tab={:backends} />

      <div
        :if={@save_error}
        id="backends-save-error"
        data-qa="backends_save_error"
        class="rounded-lg bg-red-50 border border-red-200 text-red-900 text-xs p-4"
      >
        {@save_error}
      </div>

      <div class="space-y-6" id="backends-list">
        <section
          :for={name <- Backends.backend_names()}
          id={"backend-card-#{name}"}
          data-qa={"backend_card_#{name}"}
          class="bg-slate-50 dark:bg-slate-800 shadow-xs rounded-xl border border-slate-200 dark:border-slate-700 p-6 space-y-5"
        >
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="flex items-center gap-3 min-w-0">
              <div class="flex items-center justify-center h-10 w-10 rounded-lg bg-indigo-50 text-indigo-600 shrink-0">
                <.icon name={backend_icon(name)} class="h-6 w-6" />
              </div>

              <div class="flex flex-wrap items-center gap-2 min-w-0">
                <span
                  class="text-base font-bold text-slate-900 dark:text-slate-100"
                  id={"backend-name-#{name}"}
                >
                  {display_name(name)}
                </span>

                <% account = account_for(@accounts, name) %>
                <span
                  :if={account && account.account_label not in [nil, ""]}
                  class="text-sm text-slate-500 dark:text-slate-400 truncate max-w-xs"
                  id={"account-label-#{name}"}
                >
                  {account.account_label}
                </span>

                <span
                  :if={account && account.account_detail not in [nil, ""]}
                  class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] font-bold uppercase tracking-wider bg-slate-100 dark:bg-slate-700 text-slate-900 dark:text-slate-100 ring-1 ring-inset ring-slate-200 dark:ring-slate-700"
                  id={"account-detail-#{name}"}
                >
                  {String.upcase(account.account_detail)}
                </span>

                <% badge = status_badge(account && account.status) %>
                <span
                  class={"inline-flex items-center px-2 py-0.5 rounded text-xs font-semibold #{badge.class}"}
                  id={"status-badge-#{name}"}
                >
                  {badge.label}
                </span>
              </div>
            </div>

            <div
              :if={account && not is_nil(account.fetched_at)}
              class="flex items-center gap-1.5 text-xs text-slate-500 dark:text-slate-400 shrink-0"
              id={"fetched-at-#{name}"}
            >
              <.icon name="pi-clock" class="h-3.5 w-3.5" />
              <span>read {format_age(account.fetched_at, @now)}</span>
            </div>
          </div>

          <form phx-change="validate" phx-submit="save" id={"backend-form-#{name}"}>
            <input type="hidden" name="backend" value={name} />

            <div class="space-y-4">
              <div>
                <label
                  class="block text-xs font-medium text-slate-900 dark:text-slate-100"
                  for={"executable-path-#{name}"}
                >
                  Executable path *
                </label>
                <input
                  type="text"
                  name="executable_path"
                  id={"executable-path-#{name}"}
                  data-qa={"executable_path_#{name}"}
                  value={draft(@drafts, name)["executable_path"]}
                  placeholder={"/usr/local/bin/#{name}"}
                  class="mt-1 block w-full rounded-md border-slate-200 dark:border-slate-700 shadow-xs focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs font-mono"
                />
              </div>

              <div class="space-y-2">
                <div class="flex items-center justify-between">
                  <label class="block text-xs font-medium text-slate-900 dark:text-slate-100">
                    Models
                  </label>
                  <button
                    type="button"
                    phx-click="add_model"
                    phx-value-backend={name}
                    id={"add-model-#{name}"}
                    data-qa={"add_model_#{name}"}
                    class="text-[11px] text-indigo-600 hover:text-indigo-800"
                  >
                    Add model
                  </button>
                </div>

                <p
                  :if={Enum.empty?(draft(@drafts, name)["models"])}
                  class="text-xs text-slate-500 dark:text-slate-400 italic"
                  id={"no-models-#{name}"}
                >
                  No models configured. Roles using this backend will have nothing to select.
                </p>

                <div
                  :for={{model, index} <- Enum.with_index(draft(@drafts, name)["models"])}
                  class="flex items-center gap-2"
                  id={"model-row-#{name}-#{index}"}
                >
                  <input
                    type="text"
                    name={"models[#{index}][id]"}
                    id={"model-id-#{name}-#{index}"}
                    value={model["id"]}
                    placeholder="model id"
                    class="block w-1/2 rounded-md border-slate-200 dark:border-slate-700 shadow-xs focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs font-mono"
                  />
                  <input
                    type="text"
                    name={"models[#{index}][display_name]"}
                    id={"model-name-#{name}-#{index}"}
                    value={model["display_name"]}
                    placeholder="display name (optional)"
                    class="block w-1/2 rounded-md border-slate-200 dark:border-slate-700 shadow-xs focus:border-indigo-500 focus:ring-indigo-500 sm:text-xs"
                  />
                  <button
                    type="button"
                    phx-click="remove_model"
                    phx-value-backend={name}
                    phx-value-index={index}
                    id={"remove-model-#{name}-#{index}"}
                    class="text-slate-500 dark:text-slate-400 hover:text-red-600"
                    aria-label="Remove model"
                  >
                    <.icon name="pi-trash" class="h-4 w-4" />
                  </button>
                </div>
              </div>

              <div class="flex items-center gap-3">
                <button
                  type="submit"
                  id={"save-backend-#{name}"}
                  data-qa={"save_backend_#{name}"}
                  class="rounded-md bg-indigo-600 px-3 py-2 text-xs font-semibold text-white shadow-xs hover:bg-indigo-500"
                >
                  Save
                </button>
                <span
                  :if={@saved_backend == to_string(name)}
                  class="text-xs text-emerald-700"
                  id={"saved-#{name}"}
                  data-qa={"backend_saved_#{name}"}
                >
                  Saved
                </span>
              </div>
            </div>
          </form>

          <div
            :if={account && account.status in ["not_configured", "signed_out", "unavailable"]}
            id={"banner-#{name}"}
            data-qa={"backend_banner_#{name}"}
            class="flex items-start gap-3 p-4 rounded-lg bg-slate-100 dark:bg-slate-700 border border-slate-200 dark:border-slate-700 text-slate-900 dark:text-slate-100 text-xs"
          >
            <.icon
              name="pi-warning"
              class="h-5 w-5 text-slate-500 dark:text-slate-400 shrink-0 mt-0.5"
            />
            <div>
              <p class="font-medium">{status_badge(account.status).label}</p>
              <p class="mt-0.5 text-slate-500 dark:text-slate-400">
                {account.unavailable_reason || default_reason(account.status)}
              </p>
            </div>
          </div>

          <div
            :if={account != nil and account.status == "ready" and Enum.empty?(account.groups || [])}
            id={"no-quota-windows-#{name}"}
            class="py-3 text-sm text-slate-500 dark:text-slate-400 italic"
          >
            No quota windows reported for this account.
          </div>

          <div
            :if={
              account != nil and account.status == "ready" and not Enum.empty?(account.groups || [])
            }
            class="space-y-4"
            id={"groups-container-#{name}"}
          >
            <div
              :for={{group, g_idx} <- Enum.with_index(account.groups || [])}
              id={"group-section-#{name}-#{g_idx}"}
              class="rounded-lg bg-slate-100 dark:bg-slate-700 border border-slate-200 dark:border-slate-700 p-4 space-y-3"
            >
              <h3
                class="text-xs font-bold uppercase tracking-wider text-indigo-700"
                id={"group-name-#{name}-#{g_idx}"}
              >
                {group.name}
              </h3>

              <div
                class="divide-y divide-slate-200 dark:divide-slate-700"
                id={"windows-list-#{name}-#{g_idx}"}
              >
                <div
                  :for={{window, w_idx} <- Enum.with_index(extract_windows(group))}
                  id={"window-row-#{name}-#{g_idx}-#{w_idx}"}
                  class="py-2.5 first:pt-0 last:pb-0"
                >
                  <div class="flex items-center justify-between text-xs">
                    <span
                      class="font-medium text-slate-900 dark:text-slate-100"
                      id={"window-label-#{name}-#{g_idx}-#{w_idx}"}
                    >
                      {window["label"]}
                    </span>

                    <div class="flex items-center gap-3">
                      <span
                        class={"font-semibold #{text_color_class(window["remaining_percent"])}"}
                        id={"window-remaining-#{name}-#{g_idx}-#{w_idx}"}
                      >
                        {format_remaining(window["remaining_percent"], window["unmeasured_reason"])}
                      </span>

                      <span
                        class="text-slate-500 dark:text-slate-400"
                        id={"window-reset-#{name}-#{g_idx}-#{w_idx}"}
                      >
                        {format_reset_string(window["resets_at"], @now)}
                      </span>
                    </div>
                  </div>

                  <div
                    :if={not is_nil(window["remaining_percent"])}
                    id={"progress-bar-#{name}-#{g_idx}-#{w_idx}"}
                    class="mt-2 w-full bg-slate-100 dark:bg-slate-700 rounded-full h-1.5 overflow-hidden"
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
        </section>
      </div>
    </div>
    """
  end

  def handle_event("validate", params, socket) do
    {:noreply, put_draft(socket, params["backend"], params)}
  end

  def handle_event("add_model", %{"backend" => name}, socket) do
    updated =
      update_models(socket.assigns.drafts, name, fn models ->
        List.insert_at(models, -1, %{"id" => "", "display_name" => ""})
      end)

    {:noreply, assign(socket, :drafts, updated)}
  end

  def handle_event("remove_model", %{"backend" => name, "index" => index}, socket) do
    position = String.to_integer(index)
    updated = update_models(socket.assigns.drafts, name, &List.delete_at(&1, position))

    {:noreply, assign(socket, :drafts, updated)}
  end

  def handle_event("save", params, socket) do
    name = params["backend"]
    socket = put_draft(socket, name, params)
    attrs = socket.assigns.drafts |> draft(name) |> Map.take(["executable_path", "models"])

    case save(socket.assigns.current_scope, name, attrs) do
      {:ok, _backend} ->
        socket =
          socket
          |> assign(:saved_backend, name)
          |> assign(:save_error, nil)
          |> load_drafts()

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :save_error, changeset_message(changeset))}

      {:error, :not_authorized} ->
        {:noreply, assign(socket, :save_error, "You are not allowed to change backend settings.")}
    end
  end

  def handle_event("refresh_quotas", _params, socket) do
    if socket.assigns.is_refreshing do
      {:noreply, socket}
    else
      socket =
        socket
        |> assign(:is_refreshing, true)
        |> start_async(:refresh_quotas_task, fn -> Backends.refresh_usage() end)

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

  defp save(scope, name, attrs) do
    attrs = Map.put(attrs, "name", name)

    case Backends.get_backend(name) do
      %Backend{} = backend -> Backends.update_backend(scope, backend, attrs)
      nil -> Backends.create_backend(scope, attrs)
    end
  end

  defp load_drafts(socket) do
    saved = Map.new(Backends.list_backends(), &{to_string(&1.name), &1})

    drafts =
      Map.new(Backends.backend_names(), fn name ->
        key = to_string(name)

        case Map.get(saved, key) do
          %Backend{} = backend ->
            models =
              Enum.map(backend.models, &%{"id" => &1.id, "display_name" => &1.display_name})

            {key, %{"executable_path" => backend.executable_path, "models" => models}}

          nil ->
            {key, %{"executable_path" => "", "models" => []}}
        end
      end)

    assign(socket, :drafts, drafts)
  end

  defp draft(drafts, name), do: Map.get(drafts, to_string(name), %{"executable_path" => "", "models" => []})

  defp put_draft(socket, name, params) do
    key = to_string(name)

    entry = %{
      "executable_path" => params["executable_path"] || "",
      "models" => models_from_params(params["models"])
    }

    assign(socket, :drafts, Map.put(socket.assigns.drafts, key, entry))
  end

  defp models_from_params(models) when is_map(models) do
    models
    |> Enum.sort_by(fn {index, _model} -> String.to_integer(index) end)
    |> Enum.map(fn {_index, model} ->
      %{"id" => model["id"] || "", "display_name" => model["display_name"] || ""}
    end)
  end

  defp models_from_params(_other), do: []

  defp update_models(drafts, name, fun) do
    key = to_string(name)
    entry = draft(drafts, key)

    Map.put(drafts, key, Map.put(entry, "models", fun.(entry["models"])))
  end

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(List.wrap(messages), ", ")}" end)
  end

  defp account_for(accounts, name), do: Enum.find(accounts, &(&1.backend == name))

  defp display_name(:claude), do: "Claude Code"
  defp display_name(:agy), do: "Antigravity CLI"
  defp display_name(other), do: other |> to_string() |> String.capitalize()

  defp backend_icon(:claude), do: "pi-terminal-window"
  defp backend_icon(:agy), do: "pi-rocket-launch"
  defp backend_icon(_other), do: "pi-cpu"

  defp default_reason("not_configured"), do: "Executable not found or not executable. Check the path above."
  defp default_reason("signed_out"), do: "CLI is signed out. Log in via the command line to view usage limits."
  defp default_reason(_other), do: "Failed to fetch usage data from the backend CLI."

  defp status_badge("ready") do
    %{label: "Active", class: "bg-emerald-100 text-emerald-900 ring-1 ring-inset ring-emerald-200"}
  end

  defp status_badge("signed_out") do
    %{label: "Signed Out", class: "bg-amber-100 text-amber-900 ring-1 ring-inset ring-amber-200"}
  end

  defp status_badge("unavailable") do
    %{label: "Unavailable", class: "bg-red-100 text-red-900 ring-1 ring-inset ring-red-200"}
  end

  defp status_badge(other) do
    label = if is_binary(other), do: other |> String.replace("_", " ") |> String.capitalize(), else: "Not Configured"

    %{
      label: label,
      class:
        "bg-slate-100 dark:bg-slate-700 text-slate-900 dark:text-slate-100 ring-1 ring-inset ring-slate-200 dark:ring-slate-700"
    }
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
      is_nil(remaining_percent) -> "text-slate-500 dark:text-slate-400"
      remaining_percent >= 30.0 -> "text-emerald-700"
      remaining_percent >= 10.0 -> "text-amber-700"
      true -> "text-red-700"
    end
  end

  defp format_reset_string(resets_at, now) do
    case parse_datetime(resets_at) do
      %DateTime{} = dt -> "Resets #{format_reset_local(dt, now)}"
      nil -> "Reset time unknown"
    end
  end

  defp format_reset_local(%DateTime{} = dt, %DateTime{} = now) do
    hour = dt.hour
    ampm = if hour >= 12, do: "PM", else: "AM"
    h12 = rem(hour, 12)
    h12 = if h12 == 0, do: 12, else: h12
    minute_str = dt.minute |> to_string() |> String.pad_leading(2, "0")
    time_str = "#{h12}:#{minute_str} #{ampm}"

    diff_days = Date.diff(DateTime.to_date(dt), DateTime.to_date(now))

    case diff_days do
      0 ->
        "today #{time_str}"

      1 ->
        "tomorrow #{time_str}"

      _other ->
        "#{Calendar.strftime(dt, "%a %b %-d")}, #{time_str}"
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
