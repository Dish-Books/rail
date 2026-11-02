defmodule RailWeb.Components.StatusPicker do
  @moduledoc """
  One issue's status and the menu that changes it, as an icon on a list row or a labeled line in Properties. The menu
  is a popover, so no list's clipping can cut it, and the component keeps its state so the page only hands it the issue.
  """
  use RailWeb, :live_component

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue

  def mount(socket) do
    socket =
      socket
      |> assign(:open, false)
      |> assign(:statuses, nil)
      |> assign(:read_failed, false)
      |> assign(:pick_failed, false)

    {:ok, socket}
  end

  def update(assigns, socket) do
    pick_failed =
      socket.assigns.pick_failed and
        Issue.calculate_status_name(socket.assigns.issue) == Issue.calculate_status_name(assigns.issue)

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:issue, assigns.issue)
      |> assign(:current_scope, assigns.current_scope)
      |> assign(:labeled, assigns[:labeled] || false)
      |> assign(:pick_failed, pick_failed)

    {:ok, socket}
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:name, Issue.calculate_status_name(assigns.issue))
      |> assign(:shown_state, Issue.calculate_shown_state(assigns.issue))
      |> assign(:tracker, Issue.tracker_label(assigns.issue.tracker))
      |> assign(:trigger_id, trigger_id(assigns))

    ~H"""
    <div
      id={@id}
      class={if(not @labeled, do: "shrink-0")}
      phx-window-keydown={@open && "close"}
      phx-key="Escape"
      phx-target={@myself}
    >
      <button
        :if={not @labeled}
        type="button"
        id={@trigger_id}
        data-qa="issue-status-badge"
        aria-haspopup="menu"
        aria-expanded={to_string(@open)}
        title={@name}
        phx-click="toggle"
        phx-target={@myself}
        class={[
          "flex items-center justify-center w-6 h-6 -mx-1 shrink-0 rounded-md cursor-pointer hover:bg-slate-200 dark:hover:bg-slate-700 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
          @open && "bg-slate-200 dark:bg-slate-700 ring-1 ring-slate-400 dark:ring-slate-500"
        ]}
      >
        <.status_icon state={@shown_state} />
        <span class="sr-only">Status: {@name}. Change status</span>
      </button>

      <button
        :if={@labeled}
        type="button"
        id={@trigger_id}
        data-qa="issue-status"
        aria-haspopup="menu"
        aria-expanded={to_string(@open)}
        phx-click="toggle"
        phx-target={@myself}
        class={[
          "-mx-2 max-w-full flex items-center gap-2.5 px-2 py-1 rounded-lg hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
          @open && "bg-slate-100 dark:bg-slate-800"
        ]}
      >
        <.status_icon state={@shown_state} />
        <span class="min-w-0 truncate">{@name}</span>
      </button>

      <%!-- The empty click binding keeps a click on the padding off the row; stopping it would hide it from LiveView. --%>
      <div
        :if={@open}
        id={"#{@id}-menu"}
        popover="manual"
        phx-hook="StatusMenu"
        phx-mounted={JS.ignore_attributes(["style"])}
        phx-click={%JS{}}
        phx-target={@myself}
        data-trigger={@trigger_id}
        class="fixed inset-auto m-0 p-0 w-60 rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 shadow-lg"
      >
        <div
          :if={@read_failed}
          role="alert"
          class="p-3 text-xs text-slate-700 dark:text-slate-300"
        >
          <p class="flex items-start gap-2">
            <.icon name="pi-warning-circle" class="h-4 w-4 shrink-0 text-red-600 dark:text-red-400" />
            <span>{@tracker} did not answer, so the statuses are not listed.</span>
          </p>
          <button
            type="button"
            id={"#{@id}-retry"}
            phx-click="read"
            phx-target={@myself}
            class="mt-2 inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg ring-1 ring-inset ring-slate-300 dark:ring-slate-600 text-xs font-semibold cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <.icon name="pi-arrows-clockwise" class="h-3.5 w-3.5" />Try again
          </button>
        </div>

        <div :if={is_list(@statuses)} role="menu" aria-label="Change status">
          <p
            :if={@pick_failed}
            role="alert"
            class="flex items-start gap-2 px-3 py-2 border-b border-slate-200 dark:border-slate-700 text-xs text-slate-700 dark:text-slate-300"
          >
            <.icon name="pi-warning-circle" class="h-4 w-4 shrink-0 text-red-600 dark:text-red-400" />
            <span class="min-w-0 break-words">
              Could not change the status in {@tracker}. It is still {@name}.
            </span>
          </p>
          <ul role="none" class="max-h-80 overflow-y-auto p-1">
            <li :for={status <- @statuses} role="none">
              <button
                type="button"
                role="menuitem"
                id={"#{@id}-status-#{status.id}"}
                aria-current={status.name == @name && "true"}
                phx-click="pick"
                phx-value-status_id={status.id}
                phx-target={@myself}
                class={[
                  "w-full flex items-center gap-2.5 px-2 py-1.5 rounded-lg text-sm text-left cursor-pointer hover:bg-slate-100 dark:hover:bg-slate-800 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
                  status.name == @name && "bg-slate-100 dark:bg-slate-800"
                ]}
              >
                <.status_icon state={status.state} />
                <span class="flex-1 min-w-0 truncate">{status.name}</span>
                <.icon :if={status.name == @name} name="pi-check" class="h-4 w-4 shrink-0" />
                <span :if={status.name == @name} class="sr-only">Current status</span>
              </button>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  def handle_event("toggle", _params, %{assigns: %{open: true}} = socket), do: {:noreply, close(socket)}

  def handle_event("toggle", _params, %{assigns: %{statuses: nil}} = socket) do
    socket = socket |> assign(:open, true) |> assign(:read_failed, false) |> read_statuses()
    {:noreply, socket}
  end

  def handle_event("toggle", _params, socket), do: {:noreply, assign(socket, :open, true)}

  def handle_event("read", _params, socket), do: {:noreply, read_statuses(socket)}

  def handle_event("close", _params, socket), do: {:noreply, close(socket)}

  # A pick queued behind the one that closed the menu still runs, and the action reads the row again for it.
  def handle_event("pick", %{"status_id" => status_id}, socket) do
    %{statuses: statuses, issue: issue, current_scope: scope} = socket.assigns

    with %{} = status <- Enum.find(statuses || [], &(&1.id == status_id)),
         {:ok, _issue} <- Issues.set_issue_status(scope, issue, status) do
      {:noreply, close(socket)}
    else
      nil -> {:noreply, socket}
      {:error, _reason} -> {:noreply, assign(socket, :pick_failed, true)}
    end
  end

  def handle_async(:statuses, {:ok, {:ok, statuses}}, socket) do
    socket = socket |> assign(:statuses, statuses) |> assign(:read_failed, false)
    {:noreply, socket}
  end

  def handle_async(:statuses, _failed, socket), do: {:noreply, assign(socket, :read_failed, true)}

  defp read_statuses(socket) do
    %{current_scope: scope, issue: %Issue{project: project}} = socket.assigns
    start_async(socket, :statuses, fn -> Issues.get_statuses(scope, project) end)
  end

  defp close(socket), do: socket |> assign(:open, false) |> assign(:pick_failed, false)

  # Properties shows one issue, so its line keeps the id the page has always given it.
  defp trigger_id(%{labeled: true}), do: "issue-status"
  defp trigger_id(%{id: id}), do: "#{id}-trigger"
end
