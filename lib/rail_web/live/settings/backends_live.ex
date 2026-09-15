defmodule RailWeb.Settings.BackendsLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  @card "rounded-xl border border-slate-200 dark:border-slate-700/70 bg-white dark:bg-slate-800/40"
  @field "block w-full rounded-lg border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900/60 px-3 py-2.5 text-sm shadow-xs focus:border-indigo-500 focus:ring-indigo-500"
  @field_label "block text-sm font-medium text-slate-700 dark:text-slate-200"

  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(30_000, self(), :tick)
    end

    socket =
      socket
      |> assign(:page_title, "Backends")
      |> assign(:current_section, :backends)
      |> assign(:is_refreshing, false)
      |> assign(:now, DateTime.utc_now())
      |> assign(:saved_backend, nil)
      |> assign(:save_error, nil)
      |> assign(:logins, %{})
      |> assign(:expanded, MapSet.new())
      |> load_backends()

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
    assigns =
      assigns
      |> assign(:card, @card)
      |> assign(:field, @field)
      |> assign(:field_label, @field_label)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_section={@current_section}
      current_scope={@current_scope}
      is_rail_extended={@is_rail_extended}
      attention_count={@attention_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
    >
      <div class="max-w-[90rem] mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10" id="backends-settings">
        <div class="flex flex-col lg:flex-row lg:items-start lg:justify-between gap-4">
          <div>
            <h1
              class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100"
              id="backends-title"
              data-qa="backends_title"
            >
              Backends
            </h1>
            <p class="mt-1 text-sm text-slate-500 dark:text-slate-400" id="backends-subtitle">
              CLI paths, selectable models and account usage windows
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-3">
            <span
              :if={last_read = last_read_at(@accounts)}
              id="quotas-read-at"
              class="text-sm text-slate-500 dark:text-slate-400"
            >
              quotas read {read_age(last_read, @now)}
            </span>

            <.button
              phx-click="refresh_quotas"
              id="refresh-quotas-button"
              data-qa="refresh_quotas_button"
              disabled={@is_refreshing}
            >
              <.icon
                name="pi-arrows-clockwise"
                class={["h-4 w-4", @is_refreshing && "animate-spin"]}
              />
              <span>Refresh quotas</span>
            </.button>

            <div class="relative" phx-click-away={JS.hide(to: "#add-backend-menu")}>
              <.button
                variant="primary"
                id="add-backend-button"
                data-qa="add_backend_button"
                phx-click={JS.toggle(to: "#add-backend-menu")}
              >
                <.icon name="pi-plus" class="h-4 w-4" />
                <span>Add backend</span>
              </.button>

              <div
                id="add-backend-menu"
                class="hidden absolute right-0 z-10 mt-2 w-48 rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800 py-1 shadow-lg"
              >
                <button
                  :for={name <- Backend.names()}
                  type="button"
                  phx-click={
                    JS.push("add_backend", value: %{name: name}) |> JS.hide(to: "#add-backend-menu")
                  }
                  id={"add-backend-#{name}"}
                  data-qa={"add_backend_#{name}"}
                  class="flex w-full items-center gap-2 px-3 py-2 text-sm text-slate-700 dark:text-slate-200 hover:bg-slate-100 dark:hover:bg-slate-700"
                >
                  <.icon name={backend_icon(name)} class="h-4 w-4" />
                  {display_name(name)}
                </button>
              </div>
            </div>
          </div>
        </div>

        <.settings_nav current_scope={@current_scope} active_tab={:backends} />

        <div
          :if={@save_error}
          id="backends-save-error"
          data-qa="backends_save_error"
          class="rounded-lg border border-red-200 dark:border-red-400/30 bg-red-50 dark:bg-red-400/10 p-4 text-sm text-red-900 dark:text-red-200"
        >
          {@save_error}
        </div>

        <div class="space-y-4" id="backends-list">
          <p
            :if={@draft_keys == []}
            id="no-backends"
            class={[@card, "px-6 py-10 text-center text-sm text-slate-500 dark:text-slate-400"]}
          >
            No backends configured. Add one to get started.
          </p>

          <section
            :for={key <- @draft_keys}
            id={"backend-card-#{key}"}
            data-qa={"backend_card_#{key}"}
            class={[@card, "overflow-hidden"]}
          >
            <% draft = Map.fetch!(@drafts, key) %>
            <% account = Map.get(@accounts, key) %>
            <% login = Map.get(@logins, key) %>
            <% expanded = MapSet.member?(@expanded, key) %>
            <% can_sign_in = draft["name"] == :claude and not is_nil(account) %>
            <% needs_sign_in = needs_sign_in?(account) %>

            <div
              id={"backend-header-#{key}"}
              phx-click="toggle_backend"
              phx-value-key={key}
              role="button"
              aria-expanded={to_string(expanded)}
              class="flex flex-wrap items-center gap-x-6 gap-y-4 px-6 py-5 cursor-pointer hover:bg-slate-50 dark:hover:bg-slate-800/60"
            >
              <div class="flex shrink-0 items-center gap-4">
                <.icon
                  name={if expanded, do: "pi-caret-down-fill", else: "pi-caret-right-fill"}
                  class="h-3 w-3 text-slate-400"
                />
                <div class="flex h-12 w-12 shrink-0 items-center justify-center rounded-lg bg-indigo-50 dark:bg-indigo-400/10 text-indigo-600 dark:text-indigo-300">
                  <.icon name={backend_icon(draft["name"])} class="h-6 w-6" />
                </div>

                <div class="min-w-0 max-w-72">
                  <div class="flex items-center gap-2 whitespace-nowrap">
                    <span
                      class="text-lg font-semibold text-slate-900 dark:text-slate-100"
                      id={"backend-name-#{key}"}
                    >
                      {display_name(draft["name"])}
                    </span>
                    <span
                      :if={draft["label"] not in [nil, ""]}
                      class="text-sm text-slate-500 dark:text-slate-400"
                      id={"backend-label-#{key}"}
                    >
                      · {draft["label"]}
                    </span>
                    <span
                      :if={account && account.account_detail not in [nil, ""]}
                      class="rounded bg-slate-100 dark:bg-slate-700/70 px-1.5 py-0.5 font-mono text-[11px] uppercase tracking-wider text-slate-600 dark:text-slate-300"
                      id={"account-detail-#{key}"}
                    >
                      {account.account_detail}
                    </span>
                  </div>
                  <p
                    class="truncate text-sm text-slate-500 dark:text-slate-400"
                    id={"account-label-#{key}"}
                  >
                    {account_subtitle(account)}
                  </p>
                </div>
              </div>

              <div class="ml-auto flex flex-wrap items-center justify-end gap-x-6 gap-y-4">
                <div
                  :if={account && account.status == :ready && account.usage != []}
                  id={"groups-container-#{key}"}
                  class="flex flex-wrap items-end justify-end gap-x-6 gap-y-3"
                >
                  <div
                    :for={{group, g_idx} <- Enum.with_index(account.usage)}
                    id={"group-section-#{key}-#{g_idx}"}
                    class="space-y-1.5"
                  >
                    <h3
                      :if={group_heading?(group)}
                      class="font-mono text-[11px] uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400"
                      id={"group-name-#{key}-#{g_idx}"}
                    >
                      {group.name}
                    </h3>

                    <div
                      class="flex flex-wrap gap-x-6 gap-y-3"
                      id={"windows-list-#{key}-#{g_idx}"}
                    >
                      <div
                        :for={{window, w_idx} <- Enum.with_index(extract_windows(group))}
                        id={"window-row-#{key}-#{g_idx}-#{w_idx}"}
                        class="w-40 shrink-0"
                      >
                        <div class="flex items-baseline justify-between gap-2 text-sm">
                          <span
                            class="truncate text-slate-600 dark:text-slate-300"
                            id={"window-label-#{key}-#{g_idx}-#{w_idx}"}
                          >
                            {window["label"]}
                          </span>
                          <span
                            class={[
                              "font-medium tabular-nums",
                              text_color_class(window["remaining_percent"])
                            ]}
                            id={"window-remaining-#{key}-#{g_idx}-#{w_idx}"}
                            title={window["unmeasured_reason"]}
                          >
                            {format_remaining(window["remaining_percent"])}
                          </span>
                        </div>
                        <div class="mt-1.5 h-1 w-full overflow-hidden rounded-full bg-slate-200 dark:bg-slate-700">
                          <div
                            :if={is_number(window["remaining_percent"])}
                            id={"progress-bar-#{key}-#{g_idx}-#{w_idx}"}
                            class={["h-1 rounded-full", bar_color_class(window["remaining_percent"])]}
                            style={"width: #{clamp_percent(window["remaining_percent"])}%"}
                          >
                          </div>
                        </div>
                        <p
                          class="mt-1.5 truncate whitespace-nowrap text-xs text-slate-500 dark:text-slate-400"
                          id={"window-reset-#{key}-#{g_idx}-#{w_idx}"}
                          phx-hook="LocalResetTime"
                          data-at={reset_iso(window["resets_at"])}
                        >
                          {format_reset_string(window["resets_at"], @now)}
                        </p>
                      </div>
                    </div>
                  </div>
                </div>

                <p
                  :if={account && account.status == :ready && account.usage == []}
                  id={"no-quota-windows-#{key}"}
                  class="text-sm text-slate-500 dark:text-slate-400"
                >
                  No quota windows reported
                </p>

                <p
                  :if={needs_sign_in}
                  id={"quotas-unavailable-#{key}"}
                  class="text-sm text-slate-500 dark:text-slate-400"
                >
                  Quotas unavailable until sign-in
                </p>

                <.button
                  :if={
                    can_sign_in and account.status != :ready and
                      (is_nil(login) or login.step == :failed)
                  }
                  class="text-indigo-600 dark:text-indigo-300"
                  phx-click="start_login"
                  phx-value-key={key}
                  id={"start-login-#{key}"}
                  data-qa={"start_login_#{key}"}
                >
                  Sign in
                </.button>

                <span
                  :if={login && login.step == :starting}
                  id={"login-starting-#{key}"}
                  class="text-sm text-slate-500 dark:text-slate-400"
                >
                  Starting sign-in…
                </span>

                <% badge = !needs_sign_in && status_badge(account && account.status) %>
                <span
                  :if={badge}
                  class={["shrink-0 rounded-full px-3 py-1 text-sm font-medium", badge.class]}
                  id={"status-badge-#{key}"}
                >
                  {badge.label}
                </span>
              </div>
            </div>

            <div
              :if={expanded}
              id={"backend-body-#{key}"}
              class="space-y-6 border-t border-slate-200 dark:border-slate-700/70 bg-slate-50/60 dark:bg-slate-900/30 px-6 py-6"
            >
              <div
                :if={account && account.status in [:not_configured, :unavailable] && !needs_sign_in}
                id={"banner-#{key}"}
                data-qa={"backend_banner_#{key}"}
                class="flex items-start gap-3 rounded-lg border border-amber-200 dark:border-amber-400/30 bg-amber-50 dark:bg-amber-400/10 p-4 text-sm text-amber-900 dark:text-amber-100"
              >
                <.icon name="pi-warning" class="mt-0.5 h-5 w-5 shrink-0" />
                <p>{account.unavailable_reason || default_reason(account.status)}</p>
              </div>

              <div
                :if={can_sign_in and login != nil}
                id={"login-#{key}"}
                class="space-y-3 rounded-lg border border-indigo-200 dark:border-indigo-400/30 bg-indigo-50/60 dark:bg-indigo-400/10 p-4 text-sm"
              >
                <.form
                  :if={login.step in [:awaiting_code, :submitting]}
                  for={%{}}
                  phx-change="change_login_code"
                  phx-submit="submit_login_code"
                  id={"login-code-form-#{key}"}
                  class="space-y-3"
                >
                  <input type="hidden" name="key" value={key} />
                  <p class="text-slate-700 dark:text-slate-200">
                    A browser window should have opened to sign in, and this card updates
                    once it is done. If none opened,
                    <a
                      href={login.url}
                      target="_blank"
                      rel="noopener noreferrer"
                      id={"login-url-#{key}"}
                      class="font-semibold text-indigo-600 dark:text-indigo-300 hover:underline"
                    >
                      open the sign-in page
                    </a>
                    and paste the code it shows you.
                  </p>
                  <div class="flex flex-col sm:flex-row sm:items-center gap-2">
                    <input
                      type="text"
                      name="code"
                      id={"login-code-#{key}"}
                      data-qa={"login_code_#{key}"}
                      value={login.code}
                      autocomplete="off"
                      placeholder="code"
                      class={[@field, "font-mono"]}
                    />
                    <div class="flex items-center gap-2">
                      <.button
                        type="submit"
                        variant="primary"
                        id={"submit-login-code-#{key}"}
                        disabled={login.step == :submitting}
                      >
                        {if login.step == :submitting, do: "Signing in…", else: "Finish sign-in"}
                      </.button>
                      <.button
                        variant="ghost"
                        phx-click="cancel_login"
                        phx-value-key={key}
                        id={"cancel-login-#{key}"}
                      >
                        Cancel
                      </.button>
                    </div>
                  </div>
                </.form>

                <p
                  :if={login.error}
                  id={"login-error-#{key}"}
                  class="text-red-700 dark:text-red-300"
                >
                  {login.error}
                </p>
              </div>

              <form
                phx-change="validate"
                phx-submit="save"
                id={"backend-form-#{key}"}
                class="space-y-6"
              >
                <input type="hidden" name="key" value={key} />

                <div class="grid grid-cols-1 gap-6 md:grid-cols-2">
                  <div class="space-y-2">
                    <label class={@field_label} for={"label-#{key}"}>Label</label>
                    <input
                      type="text"
                      name="label"
                      id={"label-#{key}"}
                      data-qa={"label_#{key}"}
                      value={draft["label"]}
                      placeholder="work, personal…"
                      class={@field}
                    />
                  </div>

                  <div class="space-y-2">
                    <div class="flex items-center justify-between">
                      <label class={@field_label} for={"executable-path-#{key}"}>
                        Executable path <span class="text-red-500">*</span>
                      </label>
                      <span
                        :if={draft["executable_path"] != ""}
                        id={"executable-found-#{key}"}
                        class={[
                          "text-sm",
                          executable?(draft["executable_path"]) &&
                            "text-emerald-600 dark:text-emerald-400",
                          !executable?(draft["executable_path"]) && "text-red-600 dark:text-red-400"
                        ]}
                      >
                        {if executable?(draft["executable_path"]), do: "✓ found", else: "not found"}
                      </span>
                    </div>
                    <input
                      type="text"
                      name="executable_path"
                      id={"executable-path-#{key}"}
                      data-qa={"executable_path_#{key}"}
                      value={draft["executable_path"]}
                      placeholder={"/usr/local/bin/#{draft["name"]}"}
                      class={[@field, "font-mono"]}
                    />
                  </div>
                </div>

                <div class="space-y-3">
                  <div class="flex items-center justify-between">
                    <span class={@field_label}>
                      Models
                      <span class="text-slate-400 dark:text-slate-500">
                        · {length(draft["models"])}
                      </span>
                    </span>
                    <button
                      :if={!draft["adding_model"]}
                      type="button"
                      phx-click="show_add_model"
                      phx-value-key={key}
                      id={"add-model-#{key}"}
                      data-qa={"add_model_#{key}"}
                      class="text-sm font-medium text-indigo-600 dark:text-indigo-300 hover:underline"
                    >
                      + Add model
                    </button>
                  </div>

                  <p
                    :if={draft["models"] == [] and !draft["adding_model"]}
                    class="text-sm text-slate-500 dark:text-slate-400"
                    id={"no-models-#{key}"}
                  >
                    No models yet. Roles using this backend will have nothing to select.
                  </p>

                  <div :if={draft["models"] != []} class="flex flex-wrap gap-2">
                    <span
                      :for={{model, index} <- Enum.with_index(draft["models"])}
                      id={"model-row-#{key}-#{index}"}
                      class="inline-flex items-center gap-2 rounded-full border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900/60 py-1.5 pl-4 pr-2 text-sm"
                    >
                      <input
                        type="hidden"
                        name={"models[#{index}][id]"}
                        id={"model-id-#{key}-#{index}"}
                        value={model["id"]}
                      />
                      <input
                        type="hidden"
                        name={"models[#{index}][display_name]"}
                        id={"model-name-#{key}-#{index}"}
                        value={model["display_name"]}
                      />
                      <span
                        :if={model["display_name"] not in ["", model["id"]]}
                        class="font-medium text-slate-900 dark:text-slate-100"
                      >
                        {model["display_name"]}
                      </span>
                      <span class="font-mono text-xs text-slate-500 dark:text-slate-400">
                        {model["id"]}
                      </span>
                      <button
                        type="button"
                        phx-click="remove_model"
                        phx-value-key={key}
                        phx-value-index={index}
                        id={"remove-model-#{key}-#{index}"}
                        class="rounded-full p-1 text-slate-400 hover:bg-slate-100 dark:hover:bg-slate-700 hover:text-slate-700 dark:hover:text-slate-200"
                        aria-label={"Remove #{model["id"]}"}
                      >
                        <.icon name="pi-x" class="h-3 w-3" />
                      </button>
                    </span>
                  </div>

                  <div
                    :if={draft["adding_model"]}
                    id={"new-model-#{key}"}
                    class="flex flex-col sm:flex-row sm:items-center gap-2"
                  >
                    <input
                      type="text"
                      name="new_model[id]"
                      id={"new-model-id-#{key}"}
                      value={draft["new_model"]["id"]}
                      placeholder="model id, e.g. claude-opus-5"
                      class={[@field, "font-mono"]}
                    />
                    <input
                      type="text"
                      name="new_model[display_name]"
                      id={"new-model-name-#{key}"}
                      value={draft["new_model"]["display_name"]}
                      placeholder="display name (optional)"
                      class={@field}
                    />
                    <.button
                      phx-click="add_model"
                      phx-value-key={key}
                      id={"confirm-add-model-#{key}"}
                    >
                      Add
                    </.button>
                  </div>
                </div>

                <div class="flex flex-wrap items-center gap-3 border-t border-slate-200 dark:border-slate-700/70 pt-6">
                  <.button
                    :if={
                      can_sign_in and account.status == :ready and
                        (is_nil(login) or login.step == :failed)
                    }
                    phx-click="logout"
                    phx-value-key={key}
                    id={"logout-#{key}"}
                    data-qa={"logout_#{key}"}
                  >
                    Sign out
                  </.button>

                  <div class="ml-auto flex items-center gap-3">
                    <span
                      :if={@saved_backend == key}
                      class="text-sm text-emerald-600 dark:text-emerald-400"
                      id={"saved-#{key}"}
                      data-qa={"backend_saved_#{key}"}
                    >
                      Saved
                    </span>
                    <.button
                      variant="ghost"
                      phx-click="discard"
                      phx-value-key={key}
                      id={"discard-backend-#{key}"}
                    >
                      Discard
                    </.button>
                    <.button
                      type="submit"
                      variant="primary"
                      id={"save-backend-#{key}"}
                      data-qa={"save_backend_#{key}"}
                    >
                      Save
                    </.button>
                  </div>
                </div>
              </form>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def handle_event("toggle_backend", %{"key" => key}, socket) do
    expanded = socket.assigns.expanded
    toggled = if MapSet.member?(expanded, key), do: MapSet.delete(expanded, key), else: MapSet.put(expanded, key)

    {:noreply, assign(socket, :expanded, toggled)}
  end

  def handle_event("validate", params, socket) do
    {:noreply, put_draft(socket, params["key"], params)}
  end

  # A new backend is only a draft until it is saved, keyed so it cannot collide
  # with a saved row's id, and shown open on top so it can be filled in.
  def handle_event("add_backend", %{"name" => name}, socket) do
    name = Enum.find(Backend.names(), &(to_string(&1) == name))
    key = "new-#{System.unique_integer([:positive])}"

    socket =
      socket
      |> assign(:drafts, Map.put(socket.assigns.drafts, key, new_draft(name)))
      |> assign(:draft_keys, [key | socket.assigns.draft_keys])
      |> expand(key)

    {:noreply, socket}
  end

  def handle_event("show_add_model", %{"key" => key}, socket) do
    {:noreply, update_draft(socket, key, &Map.put(&1, "adding_model", true))}
  end

  # The model typed into the add row is already on the draft: every keystroke
  # validates the form it sits in.
  def handle_event("add_model", %{"key" => key}, socket) do
    socket =
      update_draft(socket, key, fn draft ->
        %{"id" => id, "display_name" => display_name} = draft["new_model"]

        case String.trim(id) do
          "" ->
            draft

          id ->
            model = %{"id" => id, "display_name" => String.trim(display_name)}

            %{
              draft
              | "models" => List.insert_at(draft["models"], -1, model),
                "new_model" => blank_model(),
                "adding_model" => false
            }
        end
      end)

    {:noreply, socket}
  end

  def handle_event("remove_model", %{"key" => key, "index" => index}, socket) do
    position = String.to_integer(index)
    {:noreply, update_draft(socket, key, &Map.update!(&1, "models", fn models -> List.delete_at(models, position) end))}
  end

  def handle_event("discard", %{"key" => "new-" <> _draft = key}, socket) do
    socket =
      socket
      |> assign(:drafts, Map.delete(socket.assigns.drafts, key))
      |> assign(:draft_keys, List.delete(socket.assigns.draft_keys, key))
      |> assign(:expanded, MapSet.delete(socket.assigns.expanded, key))

    {:noreply, socket}
  end

  def handle_event("discard", %{"key" => key}, socket) do
    draft = draft_for(Map.fetch!(socket.assigns.accounts, key))
    {:noreply, assign(socket, :drafts, Map.put(socket.assigns.drafts, key, draft))}
  end

  def handle_event("save", params, socket) do
    key = params["key"]
    socket = put_draft(socket, key, params)
    attrs = Map.take(socket.assigns.drafts[key], ["name", "label", "executable_path", "models"])

    case save(socket.assigns.current_scope, key, attrs) do
      {:ok, backend} ->
        socket =
          socket
          |> assign(:saved_backend, backend.id)
          |> assign(:save_error, nil)
          |> load_backends()
          |> expand(backend.id)

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :save_error, changeset_message(changeset))}

      {:error, :not_authorized} ->
        {:noreply, assign(socket, :save_error, "You are not allowed to change backend settings.")}
    end
  end

  # The session is this view's, so leaving the page ends a sign-in left half done.
  def handle_event("start_login", %{"key" => key}, socket) do
    %{current_scope: scope, accounts: accounts} = socket.assigns
    backend = Map.fetch!(accounts, key)
    view = self()

    socket =
      socket
      |> put_login(key, %{step: :starting, session: nil, url: nil, code: "", error: nil})
      |> expand(key)
      |> start_async({:start_login, key}, fn -> Tools.start_backend_login(scope, backend, view) end)

    {:noreply, socket}
  end

  # Kept as typed, so a re-render while the code is being pasted cannot lose it.
  def handle_event("change_login_code", %{"key" => key, "code" => code}, socket) do
    {:noreply, put_login(socket, key, %{Map.fetch!(socket.assigns.logins, key) | code: code})}
  end

  def handle_event("submit_login_code", %{"key" => key, "code" => code}, socket) do
    %{current_scope: scope, logins: logins} = socket.assigns
    %{session: session} = login = Map.fetch!(logins, key)

    # A signed-in account is only worth showing once its usage has been read.
    submit = fn ->
      with :ok <- Tools.submit_backend_login_code(scope, session, code), do: Tools.refresh_usage()
    end

    socket =
      socket
      |> put_login(key, %{login | step: :submitting, code: code, error: nil})
      |> start_async({:submit_login_code, key}, submit)

    {:noreply, socket}
  end

  def handle_event("cancel_login", %{"key" => key}, socket) do
    with %{session: session} when is_pid(session) <- socket.assigns.logins[key] do
      Tools.cancel_backend_login(socket.assigns.current_scope, session)
    end

    {:noreply, assign(socket, :logins, Map.delete(socket.assigns.logins, key))}
  end

  def handle_event("logout", %{"key" => key}, socket) do
    %{current_scope: scope, accounts: accounts} = socket.assigns

    socket =
      case Tools.logout_backend(scope, Map.fetch!(accounts, key)) do
        {:ok, _signed_out} ->
          socket
          |> assign(:logins, Map.delete(socket.assigns.logins, key))
          |> merge_backends(Tools.list_backends())

        {:error, reason} ->
          put_login(socket, key, %{step: :failed, session: nil, url: nil, code: "", error: login_error(reason)})
      end

    {:noreply, socket}
  end

  def handle_event("refresh_quotas", _params, socket) do
    if socket.assigns.is_refreshing do
      {:noreply, socket}
    else
      socket =
        socket
        |> assign(:is_refreshing, true)
        |> start_async(:refresh_quotas_task, fn -> Tools.refresh_usage() end)

      {:noreply, socket}
    end
  end

  # Nothing announces new usage any more, so the tick only moves the clock the
  # ages are measured against. Refreshing is the button's job.
  def handle_info(:tick, socket) do
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  # The CLI finished signing in by itself, through the browser it opened, so
  # there is no code to wait for: what is left is reading the account.
  def handle_info({:backend_login_exited, session, result}, socket) do
    case Enum.find(socket.assigns.logins, fn {_key, login} -> login.session == session end) do
      {key, login} when result == :ok ->
        socket =
          socket
          |> put_login(key, %{login | step: :submitting, error: nil})
          |> start_async({:submit_login_code, key}, fn -> Tools.refresh_usage() end)

        {:noreply, socket}

      {key, _login} ->
        {:error, reason} = result
        {:noreply, put_login(socket, key, %{step: :failed, session: nil, url: nil, code: "", error: login_error(reason)})}

      nil ->
        {:noreply, socket}
    end
  end

  # The navigation hook subscribes this view to pipeline events it does not use.
  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  def handle_async(:refresh_quotas_task, {:ok, {:ok, _refreshed}}, socket) do
    socket =
      socket
      |> merge_backends(Tools.list_backends())
      |> assign(:is_refreshing, false)
      |> assign(:now, DateTime.utc_now())

    {:noreply, socket}
  end

  def handle_async(:refresh_quotas_task, _result, socket) do
    {:noreply, assign(socket, :is_refreshing, false)}
  end

  def handle_async({:start_login, key}, {:ok, {:ok, %{session: session, url: url}}}, socket) do
    {:noreply, put_login(socket, key, %{step: :awaiting_code, session: session, url: url, code: "", error: nil})}
  end

  def handle_async({:start_login, key}, result, socket) do
    {:noreply, put_login(socket, key, %{step: :failed, session: nil, url: nil, code: "", error: login_error(result)})}
  end

  # A failed code leaves the CLI gone, so the next try starts a fresh sign-in.
  def handle_async({:submit_login_code, key}, {:ok, {:ok, _refreshed}}, socket) do
    socket =
      socket
      |> assign(:logins, Map.delete(socket.assigns.logins, key))
      |> merge_backends(Tools.list_backends())
      |> assign(:now, DateTime.utc_now())

    {:noreply, socket}
  end

  def handle_async({:submit_login_code, key}, result, socket) do
    {:noreply, put_login(socket, key, %{step: :failed, session: nil, url: nil, code: "", error: login_error(result)})}
  end

  defp save(scope, "new-" <> _draft, attrs), do: Tools.create_backend(scope, attrs)

  defp save(scope, id, attrs) do
    {:ok, %Backend{} = backend} = Tools.get_backend(id)
    Tools.update_backend(scope, backend, attrs)
  end

  # One read feeds both the probe status the cards show and the form drafts, so
  # the two can never disagree about what is configured. Unsaved drafts are
  # dropped: a reload follows a save, and only the saved one survives it.
  defp load_backends(socket) do
    socket
    |> assign(:drafts, %{})
    |> assign(:draft_keys, [])
    |> merge_backends(Tools.list_backends())
  end

  # A refresh brings in probe results without clobbering a form mid-edit: only a
  # backend with no card yet gets a draft.
  defp merge_backends(socket, backends) do
    %{drafts: drafts, draft_keys: draft_keys} = socket.assigns
    added = Enum.reject(backends, &Map.has_key?(drafts, &1.id))
    {saved_keys, new_keys} = Enum.split_with(draft_keys, &(not String.starts_with?(&1, "new-")))

    socket
    |> assign(:accounts, Map.new(backends, &{&1.id, &1}))
    |> assign(:drafts, Enum.reduce(added, drafts, &Map.put(&2, &1.id, draft_for(&1))))
    |> assign(:draft_keys, new_keys ++ saved_keys ++ Enum.map(added, & &1.id))
  end

  defp expand(socket, key), do: assign(socket, :expanded, MapSet.put(socket.assigns.expanded, key))

  defp new_draft(name) do
    %{
      "name" => name,
      "label" => "",
      "executable_path" => "",
      "models" => [],
      "new_model" => blank_model(),
      "adding_model" => false
    }
  end

  defp draft_for(%Backend{} = backend) do
    %{
      new_draft(backend.name)
      | "label" => backend.label || "",
        "executable_path" => backend.executable_path,
        "models" => Enum.map(backend.models, &%{"id" => &1.id, "display_name" => &1.display_name})
    }
  end

  defp blank_model, do: %{"id" => "", "display_name" => ""}

  # The name is fixed when the draft is added, so the form never changes it.
  defp put_draft(socket, key, params) do
    update_draft(socket, key, fn draft ->
      Map.merge(draft, %{
        "label" => params["label"] || "",
        "executable_path" => params["executable_path"] || "",
        "models" => models_from_params(params["models"]),
        "new_model" => Map.merge(blank_model(), Map.take(params["new_model"] || %{}, ["id", "display_name"]))
      })
    end)
  end

  defp update_draft(socket, key, fun) do
    assign(socket, :drafts, Map.update!(socket.assigns.drafts, key, fun))
  end

  defp models_from_params(models) when is_map(models) do
    models
    |> Enum.sort_by(fn {index, _model} -> String.to_integer(index) end)
    |> Enum.map(fn {_index, model} ->
      %{"id" => model["id"] || "", "display_name" => model["display_name"] || ""}
    end)
  end

  defp models_from_params(_other), do: []

  defp put_login(socket, key, login), do: assign(socket, :logins, Map.put(socket.assigns.logins, key, login))

  defp login_error({:ok, {:error, reason}}), do: login_error(reason)
  defp login_error({:exit, _reason}), do: "Sign-in crashed. Try again."
  defp login_error(:not_authorized), do: "You are not allowed to sign backends in or out."
  defp login_error(:expired), do: "Sign-in expired. Try again."
  defp login_error(:login_exited), do: "Sign-in ended before it finished. Try again."
  defp login_error(reason) when is_binary(reason), do: "Sign-in failed: #{reason}"
  defp login_error(reason), do: "Sign-in failed: #{inspect(reason)}"

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(List.wrap(messages), ", ")}" end)
  end

  defp display_name(:claude), do: "Claude Code"
  defp display_name(:agy), do: "Antigravity CLI"
  defp display_name(other), do: other |> to_string() |> String.capitalize()

  defp backend_icon(:claude), do: "pi-terminal-window"
  defp backend_icon(:agy), do: "pi-arrow-up"
  defp backend_icon(_other), do: "pi-diamond"

  defp account_subtitle(nil), do: "Not saved yet"
  defp account_subtitle(%Backend{account_label: label}) when label not in [nil, ""], do: label
  defp account_subtitle(%Backend{}), do: "Not signed in"

  # A backend waiting on an account: signed out, or with a CLI that is in place
  # but has not been asked who is signed in yet.
  defp needs_sign_in?(%Backend{status: :signed_out}), do: true
  defp needs_sign_in?(%Backend{status: :not_configured, executable_path: path}), do: executable?(path)
  defp needs_sign_in?(_other), do: false

  # A path is only worth running if it is a regular file with an execute bit.
  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  defp last_read_at(accounts) do
    accounts
    |> Map.values()
    |> Enum.map(& &1.fetched_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp read_age(fetched_at, now) do
    case format_age(DateTime.diff(now, fetched_at, :second)) do
      "<1m" -> "just now"
      age -> "#{age} ago"
    end
  end

  defp default_reason(:not_configured), do: "Executable not found or not executable. Check the path below."
  defp default_reason(_other), do: "Failed to fetch usage data from the backend CLI."

  # Signed out is said by the card itself, and a draft has nothing to report.
  defp status_badge(:ready) do
    %{label: "Active", class: "bg-emerald-100 text-emerald-800 dark:bg-emerald-400/90 dark:text-emerald-950"}
  end

  defp status_badge(:unavailable) do
    %{label: "Unavailable", class: "bg-red-100 text-red-800 dark:bg-red-400/20 dark:text-red-200"}
  end

  defp status_badge(:not_configured) do
    %{label: "Not configured", class: "bg-slate-100 text-slate-700 dark:bg-slate-700 dark:text-slate-200"}
  end

  defp status_badge(_signed_out_or_draft), do: nil

  # A group is named only when its windows do not already say what they
  # measure: "Weekly · Fable" under "Weekly" needs no heading, "5-hour" under
  # "Gemini Models" does.
  defp group_heading?(%Backend.Usage{name: name} = group) do
    prefix = String.downcase(name || "")

    case extract_windows(group) do
      [] -> true
      windows -> not Enum.all?(windows, &String.starts_with?(String.downcase(&1["label"] || ""), prefix))
    end
  end

  defp format_remaining(remaining_percent) when is_number(remaining_percent) do
    if remaining_percent == trunc(remaining_percent) do
      "#{trunc(remaining_percent)}%"
    else
      "#{:erlang.float_to_binary(remaining_percent / 1.0, decimals: 1)}%"
    end
  end

  defp format_remaining(_unmeasured), do: "—"

  defp bar_color_class(remaining_percent) do
    cond do
      remaining_percent >= 30.0 -> "bg-emerald-500 dark:bg-emerald-400"
      remaining_percent >= 10.0 -> "bg-amber-500 dark:bg-amber-400"
      true -> "bg-red-500 dark:bg-red-400"
    end
  end

  defp text_color_class(remaining_percent) do
    cond do
      not is_number(remaining_percent) -> "text-slate-500 dark:text-slate-400"
      remaining_percent >= 30.0 -> "text-emerald-600 dark:text-emerald-400"
      remaining_percent >= 10.0 -> "text-amber-600 dark:text-amber-400"
      true -> "text-red-600 dark:text-red-400"
    end
  end

  # The wording below is in UTC; `LocalResetTime` rewrites it on the viewer's
  # own clock from this instant, and has nothing to rewrite without it.
  defp reset_iso(resets_at) do
    case parse_datetime(resets_at) do
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      nil -> nil
    end
  end

  defp format_reset_string(resets_at, now) do
    case parse_datetime(resets_at) do
      %DateTime{} = dt -> "resets #{format_reset_local(dt, now)}"
      nil -> "reset time unknown"
    end
  end

  defp format_reset_local(%DateTime{} = dt, %DateTime{} = now) do
    time_str = Calendar.strftime(dt, "%-I:%M %p")

    case Date.diff(DateTime.to_date(dt), DateTime.to_date(now)) do
      0 -> "today #{time_str}"
      1 -> "tomorrow #{time_str}"
      _other -> "#{Calendar.strftime(dt, "%a %-d")}, #{time_str}"
    end
  end

  defp extract_windows(%Backend.Usage{details: details}) when is_map(details) do
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
