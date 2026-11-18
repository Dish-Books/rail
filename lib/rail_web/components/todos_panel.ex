defmodule RailWeb.Components.TodosPanel do
  @moduledoc """
  The top bar's To-dos button and the panel it opens beside every page: the signed-in person's open to-dos
  and the ones checked off today, in their own order. The browser keeps whether it is open and reports its zone.
  """
  use RailWeb, :live_component

  alias Rail.Todos
  alias Rail.Todos.Schemas.Todo

  @id "todos-panel"

  # What `TodosDrop` switches on: the line before a row or at the list's end, and the row being moved.
  @row_marks "data-[drop-before]:before:absolute data-[drop-before]:before:-top-[2px] data-[drop-before]:before:inset-x-2 data-[drop-before]:before:h-0.5 data-[drop-before]:before:rounded-full data-[drop-before]:before:bg-indigo-400 data-[moving]:opacity-40 data-[moving]:outline-1 data-[moving]:outline-dashed data-[moving]:outline-slate-500"
  @list_marks "data-[drop-end]:after:block data-[drop-end]:after:mx-2 data-[drop-end]:after:h-0.5 data-[drop-end]:after:rounded-full data-[drop-end]:after:bg-indigo-400"

  @doc """
  The component's DOM id, for mounting it once per page and for `send_update/3`.
  """
  def id, do: @id

  def mount(socket) do
    socket =
      socket
      |> assign(:open, false)
      |> assign(:time_zone, nil)
      |> assign(:checked_off, [])
      |> assign(:form_key, 0)
      |> assign(:focus_field, false)
      |> assign(:changeset, Todo.changeset(%Todo{}, %{}))

    {:ok, socket}
  end

  def update(%{refresh: true}, socket), do: {:ok, load_todos(socket)}

  # From `NavHook` as the page connects: the browser's time zone, and whether it left the panel open.
  def update(%{browser: %{open: open, time_zone: time_zone}}, socket) do
    socket =
      socket
      |> assign(:time_zone, time_zone)
      |> assign(:open, socket.assigns.open or open)
      |> load_todos()

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket = assign(socket, :current_scope, assigns.current_scope)
    socket = if socket.assigns[:todos], do: socket, else: load_todos(socket)
    {:ok, socket}
  end

  def render(assigns) do
    rows = Enum.sort_by(assigns.todos ++ assigns.checked_off, &{&1.position, &1.id})

    assigns =
      assigns
      |> assign(:rows, rows)
      |> assign(:count, length(assigns.todos))
      |> assign(:done_today, length(assigns.checked_off))
      |> assign(:show_empty, rows == [])
      |> assign(:show_export, assigns.checked_off != [])
      |> assign(:row_marks, @row_marks)
      |> assign(:list_marks, @list_marks)

    ~H"""
    <div id={id()} class="flex items-center" phx-hook="TodosOpen">
      <button
        type="button"
        id="todos-button"
        data-qa="todos_button"
        phx-click={if @open, do: "close", else: "open"}
        phx-target={@myself}
        aria-expanded={to_string(@open)}
        aria-controls="todos-sheet"
        title="To-dos"
        class={[
          "inline-flex items-center h-8 px-2.5 rounded-lg text-xs font-semibold text-slate-700 dark:text-slate-200 focus-visible:outline-2 focus-visible:outline-blue-500",
          @open &&
            "bg-slate-200 dark:bg-slate-700 ring-1 ring-inset ring-slate-400 dark:ring-slate-500",
          !@open && "hover:bg-slate-100 dark:hover:bg-slate-700"
        ]}
      >
        <.icon name="pi-check-square" class="h-4 w-4 mr-1.5" />To-dos
        <span
          :if={@count > 0}
          id="todos-count"
          data-qa="todos_count"
          class="ml-1 px-1.5 rounded-full text-[10px] font-semibold tabular-nums bg-slate-200 dark:bg-slate-600 text-slate-900 dark:text-slate-100"
        >
          {@count}
        </span>
      </button>

      <aside
        :if={@open}
        id="todos-sheet"
        aria-label="To-dos"
        class="fixed right-0 top-11 bottom-0 w-[440px] max-w-full z-30 flex flex-col border-l border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800"
      >
        <div class="flex items-start gap-3 p-5 border-b border-slate-200 dark:border-slate-700">
          <div class="flex-1 min-w-0">
            <p class="text-base font-semibold text-slate-900 dark:text-slate-100">To-dos</p>
            <p class="mt-0.5 text-xs text-slate-500 dark:text-slate-400">
              Only you see these. Drop a link here to add it.
            </p>
          </div>
          <span
            id="todos-sheet-count"
            data-qa="todos_sheet_count"
            class="pt-0.5 font-mono text-xs text-slate-500 dark:text-slate-400"
          >
            {@count} {if @count == 1, do: "to-do", else: "to-dos"}
          </span>
          <button
            type="button"
            id="todos-close"
            data-qa="todos_close"
            phx-click="close"
            phx-target={@myself}
            aria-label="Close"
            class="h-8 w-8 -mt-1 shrink-0 rounded-md flex items-center justify-center text-slate-400 hover:bg-slate-200 dark:hover:bg-slate-700 focus-visible:outline-2 focus-visible:outline-blue-500"
          >
            <.icon name="pi-x" class="h-4 w-4" />
          </button>
        </div>

        <div
          id="todos-drop"
          phx-hook="TodosDrop"
          phx-target={@myself}
          class="group flex-1 overflow-y-auto p-5 space-y-4 data-[dragging]:outline-2 data-[dragging]:outline-dashed data-[dragging]:outline-indigo-400 data-[dragging]:-outline-offset-8 data-[dragging]:bg-indigo-500/5"
        >
          <.form
            :let={f}
            for={@changeset}
            id={"todo-form-#{@form_key}"}
            data-qa="todo_form"
            phx-change="draft"
            phx-submit="add"
            phx-target={@myself}
            class="flex items-center gap-2 rounded-lg border border-slate-200 dark:border-slate-700/80 bg-white dark:bg-slate-950/60 shadow-xs px-3 py-2 focus-within:border-indigo-500 focus-within:ring-1 focus-within:ring-indigo-500"
          >
            <.icon name="pi-plus" class="h-4 w-4 text-slate-400" />
            <label for={"todo-body-#{@form_key}"} class="sr-only">New to-do</label>
            <input
              id={"todo-body-#{@form_key}"}
              data-qa="todo_body"
              name={f[:body].name}
              value={f[:body].value}
              type="text"
              maxlength="500"
              autocomplete="off"
              placeholder="Add a to-do and press Enter"
              phx-mounted={@focus_field && JS.focus()}
              phx-debounce="300"
              class="block w-full border-0 bg-transparent p-0 text-sm text-slate-900 dark:text-slate-100 placeholder:text-slate-400 dark:placeholder:text-slate-500 focus:outline-none focus:ring-0"
            />
          </.form>

          <p
            id="todos-drop-note"
            class="hidden group-data-[dragging]:flex items-center justify-center gap-2 rounded-lg border border-indigo-400/40 bg-indigo-500/10 px-3 py-2.5 text-sm font-semibold text-indigo-700 dark:text-indigo-200"
          >
            <.icon name="pi-arrow-down" class="h-4 w-4" />Drop to add a to-do
          </p>

          <p
            :if={@show_empty}
            id="todos-empty"
            data-qa="todos_empty"
            class="rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-5 py-6 text-sm text-center text-slate-500 dark:text-slate-400"
          >
            Nothing to do. Type one, or drop a link here.
          </p>

          <ul
            :if={@rows != []}
            id="todos-list"
            data-qa="todos_list"
            class={["space-y-0.5", @list_marks]}
          >
            <.todo_row :for={todo <- @rows} todo={todo} row_marks={@row_marks} target={@myself} />
          </ul>
        </div>

        <div
          id="todos-footer"
          data-qa="todos_footer"
          class="flex items-center gap-2.5 px-5 py-3 border-t border-slate-200 dark:border-slate-700"
        >
          <.icon
            name="pi-check-circle"
            class={[
              "h-4 w-4",
              @show_export && "text-emerald-500 dark:text-emerald-400",
              !@show_export && "text-slate-400 dark:text-slate-500"
            ]}
          />
          <span
            :if={@show_export}
            id="todos-done-today"
            class="flex-1 text-xs text-slate-500 dark:text-slate-400"
          >
            <span class="font-semibold tabular-nums text-slate-800 dark:text-slate-200">{@done_today}</span>
            checked off today
          </span>
          <span
            :if={!@show_export}
            id="todos-done-today"
            class="flex-1 text-xs text-slate-500 dark:text-slate-400"
          >
            Nothing checked off today
          </span>
          <.button
            :if={@show_export}
            id="todos-export"
            data-qa="todos_export"
            href={~p"/todos/export?#{[tz: @time_zone]}"}
            download
            size="xs"
            variant="secondary"
          >
            <.icon name="pi-download-simple" class="h-3 w-3" />Export CSV
          </.button>
        </div>
      </aside>
    </div>
    """
  end

  def handle_event("open", _params, socket) do
    socket =
      socket
      |> assign(:open, true)
      |> assign(:focus_field, true)
      |> push_event("todos-open", %{open: true})

    {:noreply, socket}
  end

  def handle_event("close", _params, socket) do
    socket = socket |> assign(:open, false) |> push_event("todos-open", %{open: false})
    {:noreply, socket}
  end

  def handle_event("draft", %{"todo" => attrs}, socket) do
    {:noreply, assign(socket, :changeset, Todo.changeset(%Todo{}, attrs))}
  end

  def handle_event("add", %{"todo" => attrs}, socket) do
    case Todos.create_todo(socket.assigns.current_scope, attrs, :after_open) do
      {:ok, _todo} ->
        socket =
          socket
          |> assign(:changeset, Todo.changeset(%Todo{}, %{}))
          |> update(:form_key, &(&1 + 1))
          |> assign(:focus_field, true)
          |> load_todos()

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  # The draft in the field stays: a drop is not what was being typed.
  def handle_event("drop_link", %{"url" => "" <> url, "text" => "" <> text, "before_id" => before_id}, socket)
      when is_binary(before_id) or is_nil(before_id) do
    _added = Todos.add_link_todo(socket.assigns.current_scope, url, text, before_id || :last)
    {:noreply, load_todos(socket)}
  end

  def handle_event("drop_text", %{"text" => "" <> text, "before_id" => before_id}, socket)
      when is_binary(before_id) or is_nil(before_id) do
    _added = Todos.create_todo(socket.assigns.current_scope, %{"body" => text}, before_id || :last)
    {:noreply, load_todos(socket)}
  end

  # A row another tab has since taken off the list is not here to move.
  def handle_event("move", %{"todo_id" => "" <> todo_id, "before_id" => before_id}, socket)
      when is_binary(before_id) or is_nil(before_id) do
    with %Todo{} = todo <- Enum.find(socket.assigns.todos ++ socket.assigns.checked_off, &(&1.id == todo_id)) do
      _moved = Todos.move_todo(socket.assigns.current_scope, todo, before_id || :last)
    end

    {:noreply, load_todos(socket)}
  end

  # The browser sends these; one missing what it needs is ignored rather than crashing the page.
  def handle_event(event, _malformed, socket) when event in ["drop_link", "drop_text", "move"], do: {:noreply, socket}

  # Each sends the state its checkbox shows, so a second click on a row already in that state does nothing.
  def handle_event("check", %{"todo_id" => todo_id}, socket) do
    with %Todo{} = todo <- Enum.find(socket.assigns.todos, &(&1.id == todo_id)) do
      _checked = Todos.complete_todo(socket.assigns.current_scope, todo)
    end

    {:noreply, load_todos(socket)}
  end

  def handle_event("uncheck", %{"todo_id" => todo_id}, socket) do
    with %Todo{} = todo <- Enum.find(socket.assigns.checked_off, &(&1.id == todo_id)) do
      _reopened = Todos.reopen_todo(socket.assigns.current_scope, todo)
    end

    {:noreply, load_todos(socket)}
  end

  attr :todo, Todo, required: true
  attr :row_marks, :string, required: true
  attr :target, :any, required: true

  defp todo_row(assigns) do
    url = assigns.todo.url

    assigns =
      assigns
      |> assign(:done, is_struct(assigns.todo.completed_at, DateTime))
      |> assign(:rail_link, is_binary(url) and String.starts_with?(url, "/"))
      |> assign(:outside_link, is_binary(url) and not String.starts_with?(url, "/"))

    ~H"""
    <li
      id={"todo-#{@todo.id}"}
      data-qa="todo_row"
      data-todo-row={@todo.id}
      class={[
        "relative flex items-start gap-3 px-3 py-2.5 rounded-lg hover:bg-slate-100 dark:hover:bg-slate-800/70",
        @row_marks
      ]}
    >
      <button
        type="button"
        id={"todo-handle-#{@todo.id}"}
        data-qa="todo_handle"
        data-todo-handle={@todo.id}
        aria-label={"Move: #{@todo.body}"}
        title="Drag to move, or press the arrow keys"
        class="-ml-1.5 mt-px h-[18px] w-4 shrink-0 flex items-center justify-center rounded cursor-grab text-slate-500 dark:text-slate-400 hover:text-slate-800 dark:hover:text-slate-100 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-blue-500"
      >
        <.icon name="pi-dots-six-vertical-bold" class="h-[15px] w-[15px]" />
      </button>
      <button
        type="button"
        id={"todo-check-#{@todo.id}"}
        role="checkbox"
        aria-checked={to_string(@done)}
        aria-label={if @done, do: "Uncheck: #{@todo.body}", else: "Check off: #{@todo.body}"}
        data-qa="todo_check"
        data-todo-check={@todo.id}
        phx-click={if @done, do: "uncheck", else: "check"}
        phx-value-todo_id={@todo.id}
        phx-target={@target}
        class={[
          "mt-px h-[18px] w-[18px] shrink-0 rounded border-2 flex items-center justify-center focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
          @done && "border-emerald-500 bg-emerald-500 text-white hover:bg-emerald-600",
          !@done && "border-slate-400 dark:border-slate-500 hover:border-emerald-500"
        ]}
      >
        <.icon :if={@done} name="pi-check-bold" class="h-[11px] w-[11px]" />
      </button>
      <span
        :if={is_nil(@todo.url)}
        data-qa="todo_body_text"
        class={[
          "min-w-0 flex-1 text-sm leading-5 break-words [overflow-wrap:anywhere]",
          @done && "line-through text-slate-500 decoration-slate-500",
          !@done && "text-slate-800 dark:text-slate-200"
        ]}
      >
        {@todo.body}
      </span>
      <.link
        :if={@rail_link}
        navigate={@todo.url}
        draggable="false"
        data-qa="todo_link"
        class={[
          "min-w-0 flex-1 text-sm leading-5 underline underline-offset-2 hover:decoration-slate-300 break-words [overflow-wrap:anywhere] rounded focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
          @done && "line-through text-slate-500 decoration-slate-500",
          !@done &&
            "text-slate-900 dark:text-slate-100 decoration-slate-400 dark:decoration-slate-600"
        ]}
      >
        {@todo.body}<.icon name="pi-link" class="ml-1 h-3.5 w-3.5 align-[-2px] text-slate-400" />
      </.link>
      <a
        :if={@outside_link}
        href={@todo.url}
        target="_blank"
        rel="noopener noreferrer"
        draggable="false"
        data-qa="todo_link"
        class={[
          "min-w-0 flex-1 text-sm leading-5 underline underline-offset-2 hover:decoration-slate-300 break-words [overflow-wrap:anywhere] rounded focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
          @done && "line-through text-slate-500 decoration-slate-500",
          !@done &&
            "text-slate-900 dark:text-slate-100 decoration-slate-400 dark:decoration-slate-600"
        ]}
      >
        {@todo.body}<.icon
          name="pi-arrow-square-out"
          class="ml-1 h-3.5 w-3.5 align-[-2px] text-slate-400"
        /><span class="sr-only">(opens in a new tab)</span>
      </a>
    </li>
    """
  end

  defp load_todos(socket) do
    %{current_scope: scope, time_zone: time_zone} = socket.assigns
    checked_off = if time_zone, do: Todos.list_todos(scope, checked_off_today: time_zone), else: []

    socket
    |> assign(:todos, Todos.list_todos(scope))
    |> assign(:checked_off, checked_off)
  end
end
