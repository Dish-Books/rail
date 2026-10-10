defmodule RailWeb.Settings.HostsLive do
  @moduledoc false
  use RailWeb, :live_view

  alias Rail.Tools
  alias Rail.Tools.Schemas.SandboxHost

  @setup_url "https://github.com/Dish-Books/rail/blob/main/docs/sandbox-hosts.md"

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Rail.PubSub, "sandboxes")

    socket =
      socket
      |> assign(:page_title, "Hosts")
      |> assign(:current_section, :hosts)
      |> assign(:statuses, nil)
      |> assign(:sheet, nil)
      |> assign(:sheet_host_id, nil)
      |> assign(:changeset, nil)
      |> assign(:modal, nil)
      |> assign(:trust_fingerprint, nil)
      |> assign(:error_message, nil)
      |> assign(:headroom_cpus, Rail.sandbox_headroom_cpus())
      |> assign(:headroom_memory_gb, Rail.sandbox_headroom_memory_gb())
      |> assign(:browser_cpus, Rail.browser_cpus())
      |> assign(:browser_memory_gb, Rail.browser_memory_gb())
      |> assign_sheet_status()
      |> start_async(:statuses, &Tools.list_sandbox_host_statuses/0)

    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_section={@current_section}
      current_scope={@current_scope}
      is_rail_extended={@is_rail_extended}
      attention_count={@attention_count}
      triage_count={@triage_count}
      current_project_id={@current_project_id}
      projects={@projects}
      theme={@theme}
      show_project_switcher={@show_project_switcher}
      lost_backends={@lost_backends}
    >
      <div class={[@sheet && "2xl:pr-[440px]"]}>
        <div class="max-w-[90rem] mx-auto py-10 px-4 sm:px-6 lg:px-8 space-y-10" id="hosts-settings">
          <div>
            <h1 class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100">
              Hosts
            </h1>
            <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
              Machines running Docker that Rail starts sandboxes on.
            </p>
          </div>

          <.settings_nav current_scope={@current_scope} active_tab={:hosts} />

          <div
            :if={@error_message}
            id="hosts-error-banner"
            class="rounded-md bg-red-50 p-4 border border-red-200 text-sm text-red-700 flex items-center justify-between"
          >
            <span id="hosts-error-text">{@error_message}</span>
            <button
              type="button"
              phx-click="clear_error"
              id="clear-hosts-error-button"
              class="text-red-500 hover:text-red-700 font-bold"
            >
              ✕
            </button>
          </div>

          <section id="hosts-section">
            <div class="mb-3 flex items-end justify-between gap-4">
              <h2
                id="hosts-count"
                class="text-xs font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400"
              >
                Hosts<span :if={@statuses}> · {length(@statuses)}</span>
              </h2>
              <.button size="sm" variant="primary" id="add-host-button" phx-click="open_add">
                <.icon name="pi-plus" class="h-3.5 w-3.5" /> Add host
              </.button>
            </div>
            <%!-- Seven columns need more than an iPad in portrait gives them, so the table scrolls inside its frame. --%>
            <div class="rounded-xl border border-slate-200 dark:border-slate-700/70 overflow-x-auto bg-slate-50 dark:bg-slate-800/40">
              <table class="w-full min-w-[52rem] table-fixed" id="hosts-list">
                <colgroup>
                  <col class="w-[22%]" />
                  <col class="w-[19%]" />
                  <col class="w-24" />
                  <col class="w-28" />
                  <col class="w-28" />
                  <col />
                  <col class="w-12" />
                </colgroup>
                <thead class="bg-slate-50 dark:bg-slate-800/60">
                  <tr>
                    <.th>Host</.th>
                    <.th>SSH address</.th>
                    <.th>CPUs</.th>
                    <.th>Memory</.th>
                    <.th>Image</.th>
                    <.th>Status</.th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :if={!@statuses}
                    id="hosts-loading"
                    class="border-t border-slate-200 dark:border-slate-700/70"
                  >
                    <td colspan="7" class="px-4 py-3 text-sm text-slate-500 dark:text-slate-400">
                      Reading the hosts…
                    </td>
                  </tr>
                  <.host_row
                    :for={status <- @statuses || []}
                    status={status}
                    selected={
                      @sheet == :host and status.host != nil and status.host.id == @sheet_host_id
                    }
                  />
                </tbody>
              </table>
            </div>
            <p id="hosts-note" class="mt-2 text-xs text-slate-500 dark:text-slate-400">
              CPUs and memory are what sandboxes get. Every host keeps {@headroom_cpus} CPUs and {@headroom_memory_gb} GB back, and Rail's machine also holds {@browser_cpus} CPUs and {@browser_memory_gb} GB for the browser.
            </p>
          </section>
        </div>
      </div>

      <.side_sheet :if={@sheet == :add} id="add-host-sheet" label="Add host" on_close="close_sheet">
        <:header>
          <p class="py-1 text-base font-semibold text-slate-900 dark:text-slate-100">Add host</p>
        </:header>

        <.form
          for={@changeset}
          id="add-host-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-5"
        >
          <.host_fields changeset={@changeset} placeholders={true} />
          <.button
            type="submit"
            variant="primary"
            id="save-new-host-button"
            phx-disable-with="Adding…"
            class="w-full"
          >
            <.icon name="pi-plus" class="h-3.5 w-3.5" /> Add host
          </.button>
          <p class="text-xs text-slate-500 dark:text-slate-400">
            Rail makes an SSH key for the host and shows it next, for you to add to the host. On the first connection Rail trusts the key the host offers, and refuses any other after that.
            <.setup_link id="add-host-setup-link" />
          </p>
        </.form>
      </.side_sheet>

      <.side_sheet
        :if={@sheet == :host and @sheet_status != nil}
        id="host-sheet"
        label={@sheet_status.host.name}
        on_close="close_sheet"
      >
        <:header>
          <p
            class="text-base font-semibold text-slate-900 dark:text-slate-100 truncate"
            title={@sheet_status.host.name}
          >
            {@sheet_status.host.name}
          </p>
          <div class="mt-1">
            <.host_status id="host-sheet-status" status={@sheet_status} line={false} />
          </div>
        </:header>

        <.rails_key
          :if={@sheet_status.state == :never_connected}
          host={@sheet_status.host}
          instructions={true}
        />

        <dl
          :if={@sheet_status.state in [:connected, :unreachable] and @sheet_status.cpus_total != nil}
          id="host-sheet-figures"
          class="text-xs divide-y divide-slate-200 dark:divide-slate-700/70"
        >
          <div class="flex justify-between gap-4 py-1.5">
            <dt class="text-slate-500 dark:text-slate-400">CPUs</dt>
            <dd class="font-mono text-slate-800 dark:text-slate-200 text-right">
              {@sheet_status.cpus} of {@sheet_status.cpus_total}
            </dd>
          </div>
          <div class="flex justify-between gap-4 py-1.5">
            <dt class="text-slate-500 dark:text-slate-400">Memory</dt>
            <dd class="font-mono text-slate-800 dark:text-slate-200 text-right">
              {@sheet_status.memory_gb} of {@sheet_status.memory_gb_total} GB
            </dd>
          </div>
          <div class="flex justify-between gap-4 py-1.5">
            <dt class="text-slate-500 dark:text-slate-400">Image</dt>
            <dd class="text-right min-w-0">
              <.image_status id="host-sheet-image" image={@sheet_status.image} />
              <button
                :if={match?({:failed, _reason}, @sheet_status.image)}
                type="button"
                id="retry-copy-button"
                phx-click="retry_copy"
                phx-disable-with="Queuing…"
                class="mt-1 inline-flex items-center gap-1 px-2 py-1 rounded-md text-xs font-semibold text-slate-500 dark:text-slate-400 hover:bg-blue-500/10 hover:text-blue-600 dark:hover:text-blue-400 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-500"
              >
                <.icon name="pi-arrow-clockwise" class="size-3" />Try again
              </button>
            </dd>
          </div>
          <div :if={@sheet_status.state == :connected} class="flex justify-between gap-4 py-1.5">
            <dt class="text-slate-500 dark:text-slate-400">Connected</dt>
            <dd class="font-mono text-slate-800 dark:text-slate-200 text-right">
              since <.local_time id="host-sheet-connected-since" at={@sheet_status.since} />
            </dd>
          </div>
        </dl>

        <div
          :if={@sheet_status.state == :connected and @sheet_status.trusted != nil}
          id="host-sheet-host-key"
          class="rounded-lg bg-slate-100 dark:bg-slate-900/50 px-3 py-2.5"
        >
          <p class="text-xs text-slate-500 dark:text-slate-400">Host key</p>
          <p class="mt-0.5 font-mono text-[12px] text-slate-800 dark:text-slate-200 break-all">
            {@sheet_status.trusted}
          </p>
        </div>

        <div
          :if={@sheet_status.state == :unreachable and @sheet_status.error == :host_key_changed}
          id="host-key-changed"
          class="space-y-5"
        >
          <div class="rounded-lg border border-red-200 dark:border-red-400/30 bg-red-50 dark:bg-red-400/10 p-4 space-y-1">
            <p class="text-sm font-medium text-red-800 dark:text-red-200">
              Host key changed. Rail refuses to connect.
            </p>
            <div class="divide-y divide-red-200/70 dark:divide-red-400/20">
              <div class="py-2">
                <p class="text-xs text-slate-500 dark:text-slate-400">Trusted</p>
                <p
                  id="host-key-trusted"
                  class="mt-0.5 font-mono text-[12px] text-slate-800 dark:text-slate-200 break-all"
                >
                  {@sheet_status.trusted}
                </p>
              </div>
              <div :if={@sheet_status.offered} class="py-2">
                <p class="text-xs text-slate-500 dark:text-slate-400">Offered now</p>
                <p
                  id="host-key-offered"
                  class="mt-0.5 font-mono text-[12px] text-red-700 dark:text-red-300 break-all"
                >
                  {@sheet_status.offered}
                </p>
              </div>
            </div>
            <div :if={@sheet_status.offered} class="pt-2">
              <.button
                size="sm"
                id="trust-key-button"
                phx-click="confirm_trust"
                phx-value-fingerprint={@sheet_status.offered}
              >
                <.icon name="pi-key" class="h-3.5 w-3.5" /> Trust new key
              </.button>
            </div>
          </div>
          <p class="text-xs text-slate-500 dark:text-slate-400">
            Compare the offered key with
            <span class="font-mono">ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub</span>
            on the host.
          </p>
        </div>

        <.form
          for={@changeset}
          id="edit-host-form"
          phx-change="validate"
          phx-submit="save"
          class={[
            "space-y-5",
            @sheet_status.state == :never_connected &&
              "border-t border-slate-200 dark:border-slate-700 pt-5"
          ]}
        >
          <.host_fields changeset={@changeset} placeholders={false} />

          <div
            :if={@sheet_status.state != :never_connected and @sheet_status.error != :host_key_changed}
            id="host-sheet-rails-key"
          >
            <p class="mb-1.5 block text-sm font-medium text-slate-700 dark:text-slate-200">
              Rail's key
            </p>
            <.rails_key host={@sheet_status.host} instructions={false} />
          </div>

          <div class="flex items-center justify-between gap-3">
            <.button
              type="submit"
              variant="primary"
              id="save-host-button"
              phx-disable-with="Saving…"
            >
              Save
            </.button>
            <.button variant="ghost_danger" id="remove-host-button" phx-click="confirm_remove">
              <.icon name="pi-trash" class="h-3.5 w-3.5" /> Remove host
            </.button>
          </div>
        </.form>
      </.side_sheet>
    </Layouts.app>

    <div
      :if={@modal == :remove and @sheet_status != nil}
      class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/50 p-4"
      id="remove-host-modal"
    >
      <div
        class="w-full max-w-md rounded-lg bg-slate-50 dark:bg-slate-800 p-6 shadow-xl space-y-4"
        role="dialog"
        aria-modal="true"
        aria-labelledby="remove-host-title"
      >
        <h2
          id="remove-host-title"
          class="text-base font-semibold text-slate-900 dark:text-slate-100 break-words"
        >
          Remove {@sheet_status.host.name}
        </h2>
        <p class="text-sm text-slate-500 dark:text-slate-400 break-words">
          Rail closes its connection to {@sheet_status.host.name} and starts no sandboxes there from now on.
        </p>
        <div class="flex items-center justify-end space-x-3 pt-4 border-t border-slate-200 dark:border-slate-700">
          <.button phx-click="close_modal" id="cancel-remove-host-button" phx-mounted={JS.focus()}>
            Cancel
          </.button>
          <.button
            variant="danger_solid"
            phx-click="remove"
            id="confirm-remove-host-button"
            phx-disable-with="Removing…"
          >
            Remove host
          </.button>
        </div>
      </div>
    </div>

    <div
      :if={@modal == :trust and @sheet_status != nil}
      class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/50 p-4"
      id="trust-key-modal"
    >
      <div
        class="w-full max-w-md rounded-lg bg-slate-50 dark:bg-slate-800 p-6 shadow-xl space-y-4"
        role="dialog"
        aria-modal="true"
        aria-labelledby="trust-key-title"
      >
        <h2
          id="trust-key-title"
          class="text-base font-semibold text-slate-900 dark:text-slate-100 break-words"
        >
          Trust the new key for {@sheet_status.host.name}
        </h2>
        <p class="text-sm text-slate-500 dark:text-slate-400">
          Rail will connect to whichever machine offers
          <span class="font-mono text-xs text-slate-700 dark:text-slate-300 break-all">{@trust_fingerprint}</span>
          at <span class="break-all">{@sheet_status.host.ssh_address}</span>, and refuse the old key. Trust it only if you know the host's key changed, for example after a reinstall.
        </p>
        <div class="flex items-center justify-end space-x-3 pt-4 border-t border-slate-200 dark:border-slate-700">
          <.button phx-click="close_modal" id="cancel-trust-key-button" phx-mounted={JS.focus()}>
            Cancel
          </.button>
          <.button
            variant="primary"
            phx-click="trust"
            id="confirm-trust-key-button"
            phx-disable-with="Trusting…"
          >
            Trust new key
          </.button>
        </div>
      </div>
    </div>
    """
  end

  def handle_event("open_add", _params, socket) do
    socket =
      socket
      |> assign(:sheet, :add)
      |> assign(:sheet_host_id, nil)
      |> assign(:changeset, SandboxHost.changeset(%SandboxHost{}, %{}))
      |> assign_sheet_status()

    {:noreply, socket}
  end

  def handle_event("open_host", %{"host_id" => host_id}, socket) do
    socket =
      case Enum.find(socket.assigns.statuses || [], &(&1.host && &1.host.id == host_id)) do
        %{host: host} ->
          socket
          |> assign(:sheet, :host)
          |> assign(:sheet_host_id, host.id)
          |> assign(:changeset, SandboxHost.changeset(host, %{}))
          |> assign_sheet_status()

        nil ->
          socket
      end

    {:noreply, socket}
  end

  # Escape reaches the sheet too, so with a modal open it only closes the modal.
  def handle_event("close_sheet", _params, %{assigns: %{modal: modal}} = socket) when modal != nil do
    {:noreply, assign(socket, :modal, nil)}
  end

  def handle_event("close_sheet", _params, socket) do
    socket =
      socket
      |> assign(:sheet, nil)
      |> assign(:sheet_host_id, nil)
      |> assign(:changeset, nil)
      |> assign_sheet_status()

    {:noreply, socket}
  end

  def handle_event("validate", %{"sandbox_host" => params}, socket) do
    changeset =
      socket.assigns.changeset.data
      |> SandboxHost.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"sandbox_host" => params}, %{assigns: %{sheet: :add}} = socket) do
    case Tools.create_sandbox_host(socket.assigns.current_scope, params) do
      {:ok, host} ->
        socket =
          socket
          |> assign(:sheet, :host)
          |> assign(:sheet_host_id, host.id)
          |> assign(:changeset, SandboxHost.changeset(host, %{}))
          |> reload_statuses()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, refused(socket, reason)}
    end
  end

  def handle_event("save", %{"sandbox_host" => params}, %{assigns: %{sheet: :host, sheet_status: %{host: host}}} = socket) do
    case Tools.update_sandbox_host(socket.assigns.current_scope, host, params) do
      {:ok, updated} ->
        socket =
          socket
          |> assign(:changeset, SandboxHost.changeset(updated, %{}))
          |> reload_statuses()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, refused(socket, reason)}
    end
  end

  def handle_event("confirm_remove", _params, socket), do: {:noreply, assign(socket, :modal, :remove)}

  def handle_event("remove", _params, %{assigns: %{modal: :remove, sheet_status: %{host: host}}} = socket) do
    case Tools.remove_sandbox_host(socket.assigns.current_scope, host) do
      {:ok, _removed} ->
        socket =
          socket
          |> assign(:modal, nil)
          |> assign(:sheet, nil)
          |> assign(:sheet_host_id, nil)
          |> assign(:changeset, nil)
          |> reload_statuses()

        {:noreply, socket}

      {:error, reason} ->
        socket = socket |> assign(:modal, nil) |> refused(reason)
        {:noreply, socket}
    end
  end

  def handle_event("confirm_trust", %{"fingerprint" => fingerprint}, socket) do
    socket =
      socket
      |> assign(:modal, :trust)
      |> assign(:trust_fingerprint, fingerprint)

    {:noreply, socket}
  end

  def handle_event("trust", _params, %{assigns: %{modal: :trust, sheet_status: %{host: host}}} = socket) do
    socket =
      case Tools.trust_sandbox_host_key(socket.assigns.current_scope, host, socket.assigns.trust_fingerprint) do
        {:ok, _trusted} -> reload_statuses(socket)
        {:error, reason} -> refused(socket, reason)
      end

    socket =
      socket
      |> assign(:modal, nil)
      |> assign(:trust_fingerprint, nil)

    {:noreply, socket}
  end

  def handle_event("retry_copy", _params, %{assigns: %{sheet_status: %{host: %SandboxHost{} = host}}} = socket) do
    socket =
      case Tools.retry_sandbox_image_copy(socket.assigns.current_scope, host) do
        {:ok, _host} -> reload_statuses(socket)
        {:error, reason} -> refused(socket, reason)
      end

    {:noreply, socket}
  end

  # A confirm that lands after its modal closed, from a second click or another tab.
  def handle_event(event, _params, socket) when event in ["remove", "trust", "retry_copy", "save"] do
    {:noreply, socket}
  end

  def handle_event("close_modal", _params, socket) do
    socket =
      socket
      |> assign(:modal, nil)
      |> assign(:trust_fingerprint, nil)

    {:noreply, socket}
  end

  def handle_event("clear_error", _params, socket), do: {:noreply, assign(socket, :error_message, nil)}

  def handle_info(:sandboxes_changed, socket) do
    {:noreply, start_async(socket, :statuses, &Tools.list_sandbox_host_statuses/0)}
  end

  def handle_async(:statuses, {:ok, statuses}, socket) do
    socket =
      socket
      |> assign(:statuses, statuses)
      |> assign_sheet_status()

    {:noreply, socket}
  end

  attr :status, :map, required: true
  attr :selected, :boolean, required: true

  defp host_row(%{status: %{host: nil}} = assigns) do
    ~H"""
    <tr id="host-row-local" class="border-t border-slate-200 dark:border-slate-700/70">
      <td class="px-4 py-3 max-w-0">
        <p class="text-sm font-medium text-slate-900 dark:text-slate-100 truncate">Rail's machine</p>
      </td>
      <td class="px-4 py-3 max-w-0">
        <p class="font-mono text-xs text-slate-600 dark:text-slate-300 truncate">Local</p>
      </td>
      <td class="px-4 py-3">
        <.share id="host-cpus-local" share={@status.cpus} total={@status.cpus_total} />
      </td>
      <td class="px-4 py-3">
        <.share
          id="host-memory-local"
          share={@status.memory_gb}
          total={@status.memory_gb_total}
          unit=" GB"
        />
      </td>
      <td class="px-4 py-3"><.image_status id="host-image-local" image={@status.image} /></td>
      <td class="px-4 py-3 max-w-0"><.host_status id="host-status-local" status={@status} /></td>
      <td class="px-4 py-3"></td>
    </tr>
    """
  end

  defp host_row(assigns) do
    ~H"""
    <tr
      id={"host-row-#{@status.host.id}"}
      tabindex="0"
      phx-click="open_host"
      phx-keydown="open_host"
      phx-key="Enter"
      phx-value-host_id={@status.host.id}
      aria-selected={to_string(@selected)}
      class={[
        "border-t border-slate-200 dark:border-slate-700/70 cursor-pointer focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-indigo-500",
        @selected && "bg-blue-50 dark:bg-blue-950/50 shadow-[inset_3px_0_0_0_var(--color-blue-500)]",
        !@selected && "hover:bg-slate-100 dark:hover:bg-slate-700/40"
      ]}
    >
      <td class="px-4 py-3 max-w-0">
        <p
          class="text-sm font-medium text-slate-900 dark:text-slate-100 truncate"
          title={@status.host.name}
        >
          {@status.host.name}
        </p>
      </td>
      <td class="px-4 py-3 max-w-0">
        <p
          class="font-mono text-xs text-slate-600 dark:text-slate-300 truncate"
          title={@status.host.ssh_address}
        >
          {@status.host.ssh_address}
        </p>
      </td>
      <td class="px-4 py-3">
        <.share
          id={"host-cpus-#{@status.host.id}"}
          share={@status.cpus}
          total={@status.cpus_total}
          stale={@status.state != :connected}
        />
      </td>
      <td class="px-4 py-3">
        <.share
          id={"host-memory-#{@status.host.id}"}
          share={@status.memory_gb}
          total={@status.memory_gb_total}
          unit=" GB"
          stale={@status.state != :connected}
        />
      </td>
      <td class="px-4 py-3 max-w-0">
        <.image_status id={"host-image-#{@status.host.id}"} image={@status.image} />
      </td>
      <td class="px-4 py-3 max-w-0">
        <.host_status id={"host-status-#{@status.host.id}"} status={@status} />
      </td>
      <td class="px-4 py-3 text-right">
        <.icon name="pi-caret-right" class="h-4 w-4 text-slate-400" />
      </td>
    </tr>
    """
  end

  attr :id, :string, required: true
  attr :share, :integer, default: nil
  attr :total, :integer, default: nil
  attr :unit, :string, default: ""
  attr :stale, :boolean, default: false

  defp share(%{total: nil} = assigns) do
    ~H"""
    <span id={@id} class="text-xs text-slate-500 dark:text-slate-400">—</span>
    """
  end

  defp share(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "font-mono text-xs whitespace-nowrap",
        @stale && "text-slate-500 dark:text-slate-400",
        !@stale && "text-slate-700 dark:text-slate-300"
      ]}
    >
      {@share}<span class="text-slate-500"> of {@total}{@unit}</span>
    </span>
    """
  end

  attr :changeset, Ecto.Changeset, required: true
  attr :placeholders, :boolean, required: true

  defp host_fields(assigns) do
    ~H"""
    <div>
      <.input
        label="Name"
        name="sandbox_host[name]"
        id="host-name-input"
        value={Ecto.Changeset.get_field(@changeset, :name)}
        placeholder={@placeholders && "build-04"}
        class="font-mono"
        errors={errors(@changeset, :name)}
        phx-debounce="300"
      />
      <p :if={@placeholders} class="mt-1.5 text-xs text-slate-500 dark:text-slate-400">
        Shown on the Sandboxes page.
      </p>
    </div>
    <div>
      <.input
        label="SSH address"
        name="sandbox_host[ssh_address]"
        id="host-address-input"
        value={Ecto.Changeset.get_field(@changeset, :ssh_address)}
        placeholder={@placeholders && "rail@10.0.4.14"}
        class="font-mono"
        errors={errors(@changeset, :ssh_address)}
        phx-debounce="300"
      />
      <p :if={@placeholders} class="mt-1.5 text-xs text-slate-500 dark:text-slate-400">
        user@host, with :port when it isn't 22.
      </p>
    </div>
    """
  end

  attr :host, SandboxHost, required: true
  attr :instructions, :boolean, required: true

  defp rails_key(assigns) do
    {user, _address, _port} = SandboxHost.ssh_target(assigns.host)
    assigns = assign(assigns, :user, user)

    ~H"""
    <div id={@instructions && "host-sheet-key-instructions"} class="space-y-2">
      <p :if={@instructions} class="text-sm text-slate-700 dark:text-slate-200">
        Add this key to <span class="font-mono text-xs">~/.ssh/authorized_keys</span>
        for <span id="host-sheet-key-user" class="font-mono text-xs">{@user}</span>
        on <span class="break-all">{@host.name}</span>. Rail connects as soon as it is there.
      </p>
      <div class="rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-950/60 px-3 py-2.5">
        <p
          id="host-sheet-public-key"
          class="font-mono text-[12px] leading-5 text-slate-800 dark:text-slate-200 break-all"
        >
          {@host.public_key}
        </p>
      </div>
      <div class="flex items-center justify-between gap-3">
        <button
          type="button"
          id="copy-host-key"
          phx-hook="CopyText"
          data-copy-text={@host.public_key}
          class="group inline-flex items-center gap-1 text-xs font-medium text-indigo-600 dark:text-indigo-300 hover:underline rounded cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-500"
        >
          <.icon name="pi-copy" class="size-3.5" />
          <span class="group-data-[copied]:hidden">Copy key</span>
          <span class="hidden group-data-[copied]:inline">Copied</span>
        </button>
        <.setup_link id="host-sheet-setup-link" />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true

  defp setup_link(assigns) do
    assigns = assign(assigns, :url, @setup_url)

    ~H"""
    <a
      id={@id}
      href={@url}
      target="_blank"
      rel="noopener"
      class="inline-flex items-center gap-1 text-xs font-semibold text-indigo-600 dark:text-indigo-300 hover:underline rounded focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-500"
    >
      <.icon name="pi-book-open" class="size-3.5" />How to set up a host
    </a>
    """
  end

  slot :inner_block, required: true

  defp th(assigns) do
    ~H"""
    <th class="px-4 py-2.5 text-left text-[11px] font-medium uppercase tracking-[0.14em] text-slate-500 dark:text-slate-400 whitespace-nowrap">
      {render_slot(@inner_block)}
    </th>
    """
  end

  # The page's own writes show at once; everyone else's arrive with the broadcast.
  defp reload_statuses(socket) do
    socket
    |> assign(:error_message, nil)
    |> assign(:statuses, Tools.list_sandbox_host_statuses())
    |> assign_sheet_status()
  end

  # The sheet reads its host from the statuses, so each reload refreshes it too.
  defp assign_sheet_status(socket) do
    %{statuses: statuses, sheet_host_id: id} = socket.assigns
    assign(socket, :sheet_status, Enum.find(statuses || [], &(&1.host != nil and &1.host.id == id)))
  end

  defp refused(socket, %Ecto.Changeset{} = changeset), do: assign(socket, :changeset, changeset)
  defp refused(socket, :not_authorized), do: assign(socket, :error_message, "Only admins can change hosts.")

  defp refused(socket, :key_not_offered),
    do: assign(socket, :error_message, "The host offers a different key now, so nothing was trusted. Check it again.")

  defp errors(%Ecto.Changeset{action: nil}, _field), do: []
  defp errors(changeset, field), do: changeset.errors |> Keyword.get_values(field) |> Enum.map(&elem(&1, 0))
end
