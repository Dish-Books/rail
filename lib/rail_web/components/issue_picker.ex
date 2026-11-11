defmodule RailWeb.Components.IssuePicker do
  @moduledoc """
  A search over a Rail-tracked issue's project that picks its parent, or an issue it is blocked by or blocks, as `kind`
  says. A pick applies at once; one refused keeps the menu open with the reason.
  """
  use RailWeb, :live_component

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue

  @shown 8

  def mount(socket) do
    socket =
      socket
      |> assign(:open, false)
      |> assign(:query, "")
      |> assign(:results, [])
      |> assign(:error, nil)

    {:ok, socket}
  end

  def update(assigns, socket) do
    refresh = socket.assigns.open and socket.assigns[:exclude_ids] != assigns.exclude_ids

    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:kind, assigns.kind)
      |> assign(:issue, assigns.issue)
      |> assign(:parent, assigns[:parent])
      |> assign(:exclude_ids, assigns.exclude_ids)
      |> assign(:current_scope, assigns.current_scope)

    socket = if refresh, do: search(socket), else: socket
    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="relative"
      phx-click-away={@open && JS.push("close", target: @myself)}
      phx-window-keydown={
        @open && JS.push("close", target: @myself) |> JS.focus(to: "##{trigger_id(@kind, @id)}")
      }
      phx-key="Escape"
    >
      <.trigger
        id={trigger_id(@kind, @id)}
        kind={@kind}
        open={@open}
        parent={@parent}
        target={@myself}
      />

      <div
        :if={@open}
        id={"#{@id}-menu"}
        role="menu"
        class={[
          "absolute z-20 top-full mt-1 max-w-[calc(100vw-2rem)] rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 shadow-lg",
          if(@kind == :parent, do: "right-0 w-96", else: "left-0 w-[28rem]")
        ]}
      >
        <form
          id={"#{@id}-search-form"}
          phx-change="search"
          phx-target={@myself}
          onsubmit="return false"
        >
          <input
            type="text"
            id={"#{@id}-search"}
            name="q"
            value={@query}
            phx-debounce="150"
            phx-mounted={JS.focus()}
            autocomplete="off"
            aria-label="Search issues"
            placeholder={placeholder(@kind)}
            class="w-full px-3 py-2.5 text-sm bg-transparent border-0 border-b border-slate-200 dark:border-slate-700 text-slate-900 dark:text-slate-100 placeholder-slate-400 focus:outline-none focus:ring-0"
          />
        </form>

        <p
          :if={@error}
          id={"#{@id}-error"}
          role="alert"
          class="flex items-start gap-2 px-3 py-2 border-b border-slate-200 dark:border-slate-700 text-xs text-slate-700 dark:text-slate-300"
        >
          <.icon name="pi-warning-circle" class="h-4 w-4 shrink-0 text-red-600 dark:text-red-400" />
          <span class="min-w-0 break-words">{@error}</span>
        </p>

        <ul class="max-h-80 overflow-y-auto p-1">
          <li :if={@kind == :parent}>
            <button
              type="button"
              role="menuitem"
              id={"#{@id}-none"}
              phx-click="pick"
              phx-value-issue_id=""
              phx-target={@myself}
              class="w-full flex items-center gap-2.5 px-2 py-1.5 rounded-lg text-left text-sm hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500"
            >
              <.icon name="pi-minus-circle" class="h-4 w-4 text-slate-400 dark:text-slate-500" />
              <span>No parent</span>
              <.icon :if={is_nil(@parent)} name="pi-check" class="h-4 w-4 ml-auto shrink-0" />
            </button>
          </li>
          <li :for={issue <- @results}>
            <button
              type="button"
              role="menuitem"
              id={"#{@id}-issue-#{issue.id}"}
              phx-click="pick"
              phx-value-issue_id={issue.id}
              phx-target={@myself}
              class={[
                "w-full flex items-center gap-2.5 px-2 py-1.5 rounded-lg text-left text-sm hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500",
                current?(@parent, issue) && "bg-slate-100 dark:bg-slate-800"
              ]}
            >
              <.status_icon state={Issue.calculate_shown_state(issue)} />
              <span class="w-16 shrink-0 font-mono text-xs text-slate-500 dark:text-slate-400 truncate">
                {issue.identifier}
              </span>
              <span class="min-w-0 flex-1 truncate">{issue.title}</span>
              <.icon :if={current?(@parent, issue)} name="pi-check" class="h-4 w-4 ml-auto shrink-0" />
            </button>
          </li>
          <li
            :if={@results == []}
            id={"#{@id}-empty"}
            class="px-2 py-1.5 text-sm text-slate-500 dark:text-slate-400"
          >
            No matching issues
          </li>
        </ul>
      </div>
    </div>
    """
  end

  def handle_event("toggle", _params, %{assigns: %{open: true}} = socket), do: {:noreply, close(socket)}

  def handle_event("toggle", _params, socket) do
    socket = socket |> assign(:open, true) |> assign(:query, "") |> search()
    {:noreply, socket}
  end

  def handle_event("close", _params, socket), do: {:noreply, close(socket)}

  def handle_event("search", %{"q" => query}, socket) when is_binary(query) do
    socket = socket |> assign(:query, query) |> search()
    {:noreply, socket}
  end

  def handle_event("pick", %{"issue_id" => ""}, %{assigns: %{kind: :parent}} = socket) do
    %{current_scope: scope, issue: issue} = socket.assigns
    {:noreply, applied(socket, issue, Issues.edit_issue(scope, issue, %{"parent_id" => nil}))}
  end

  # Only an issue the menu shows can be picked.
  def handle_event("pick", %{"issue_id" => issue_id}, socket) do
    %{current_scope: scope, issue: issue, kind: kind} = socket.assigns

    case Enum.find(socket.assigns.results, &(&1.id == issue_id)) do
      %Issue{} = picked -> {:noreply, applied(socket, picked, apply_pick(kind, scope, issue, picked))}
      nil -> {:noreply, socket}
    end
  end

  attr :id, :string, required: true
  attr :kind, :atom, required: true
  attr :open, :boolean, required: true
  attr :parent, :any, required: true
  attr :target, :any, required: true

  defp trigger(%{kind: :parent} = assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      data-qa="issue-parent"
      aria-haspopup="menu"
      aria-expanded={to_string(@open)}
      phx-click="toggle"
      phx-target={@target}
      class={[
        "-mx-2 w-[calc(100%+1rem)] flex items-center gap-2.5 px-2 py-1 rounded-lg text-left hover:bg-slate-100 dark:hover:bg-slate-800 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500",
        @open && "bg-slate-100 dark:bg-slate-800 ring-1 ring-slate-300 dark:ring-slate-500"
      ]}
    >
      <.icon name="pi-arrow-bend-left-up" class="h-4 w-4 text-slate-500 dark:text-slate-400" />
      <span :if={@parent} class="shrink-0 font-mono text-xs text-slate-500 dark:text-slate-400">
        {@parent.identifier}
      </span>
      <span :if={@parent} class="min-w-0 flex-1 truncate" title={@parent.title}>{@parent.title}</span>
      <span :if={!@parent} class="text-slate-400 dark:text-slate-500">No parent</span>
    </button>
    """
  end

  defp trigger(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      aria-haspopup="menu"
      aria-expanded={to_string(@open)}
      phx-click="toggle"
      phx-target={@target}
      class={[
        "inline-flex items-center gap-1.5 px-2 py-1 rounded-lg text-xs hover:bg-slate-100 dark:hover:bg-slate-800 hover:text-slate-900 dark:hover:text-slate-100 cursor-pointer focus-visible:outline-2 focus-visible:outline-blue-500",
        if(@open,
          do:
            "bg-slate-100 dark:bg-slate-800 ring-1 ring-slate-300 dark:ring-slate-500 text-slate-900 dark:text-slate-100",
          else: "text-slate-500 dark:text-slate-400"
        )
      ]}
    >
      <.icon name="pi-plus" class="h-3.5 w-3.5" />{label(@kind)}
    </button>
    """
  end

  defp search(socket) do
    %{issue: issue, query: query, exclude_ids: exclude_ids} = socket.assigns

    %{issues: results} =
      Issues.list_issues(
        project_id: issue.project_id,
        search: query,
        show_finished: true,
        exclude_ids: exclude_ids,
        limit: @shown
      )

    socket |> assign(:results, results) |> assign(:error, nil)
  end

  defp apply_pick(:parent, scope, issue, picked), do: Issues.edit_issue(scope, issue, %{"parent_id" => picked.id})
  defp apply_pick(:blocked_by, scope, issue, picked), do: Issues.block_issue(scope, picked, issue)
  defp apply_pick(:blocks, scope, issue, picked), do: Issues.block_issue(scope, issue, picked)

  defp applied(socket, %Issue{} = picked, {:error, reason}), do: assign(socket, :error, reason_text(reason, picked))
  defp applied(socket, %Issue{}, _applied), do: close(socket)

  defp close(socket), do: socket |> assign(:open, false) |> assign(:error, nil)

  defp reason_text(%Ecto.Changeset{} = changeset, %Issue{identifier: identifier}) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {_field, messages} -> messages end)
    |> Enum.map_join(". ", &"#{identifier} #{&1}")
  end

  defp reason_text(_not_found, %Issue{identifier: identifier}), do: "#{identifier} is no longer in this project."

  # Properties shows one parent, so its line keeps a plain id like the others there.
  defp trigger_id(:parent, _id), do: "issue-parent"
  defp trigger_id(_relation, id), do: "#{id}-trigger"

  defp current?(%Issue{id: id}, %Issue{id: id}), do: true
  defp current?(_parent, %Issue{}), do: false

  defp label(:blocked_by), do: "Blocked by"
  defp label(:blocks), do: "Blocks"

  defp placeholder(:parent), do: "Set parent..."
  defp placeholder(_relation), do: "Search issues..."
end
