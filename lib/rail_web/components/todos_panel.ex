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
      |> assign(:editing, nil)
      |> assign(:edit_changeset, nil)

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
            <.todo_row
              :for={todo <- @rows}
              todo={todo}
              row_marks={@row_marks}
              target={@myself}
              editing={is_struct(@editing, Todo) and @editing.id == todo.id}
              edit_changeset={@edit_changeset}
            />
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

  # A row another tab has since taken off the list is not here to edit or delete.
  def handle_event("edit", %{"todo_id" => todo_id}, socket) do
    socket =
      case Enum.find(socket.assigns.todos ++ socket.assigns.checked_off, &(&1.id == todo_id)) do
        %Todo{} = todo -> socket |> assign(:editing, todo) |> assign(:edit_changeset, Todo.changeset(todo, %{}))
        nil -> socket
      end

    {:noreply, socket}
  end

  def handle_event("edit_draft", %{"todo" => attrs}, %{assigns: %{editing: %Todo{} = todo}} = socket) do
    {:noreply, assign(socket, :edit_changeset, Todo.changeset(todo, attrs))}
  end

  def handle_event("save_edit", %{"todo" => attrs}, %{assigns: %{editing: %Todo{} = todo}} = socket) do
    socket =
      case Todos.update_todo(socket.assigns.current_scope, todo, attrs) do
        {:ok, _todo} -> socket |> close_editor(todo) |> load_todos()
        {:error, %Ecto.Changeset{} = changeset} -> assign(socket, :edit_changeset, changeset)
        {:error, :not_found} -> socket |> assign(:editing, nil) |> load_todos()
      end

    {:noreply, socket}
  end

  # Cancel just closed the editor, so a draft or save still on its way has nothing to change.
  def handle_event(event, _params, socket) when event in ["edit_draft", "save_edit"], do: {:noreply, socket}

  def handle_event("cancel_edit", _params, %{assigns: %{editing: %Todo{} = todo}} = socket) do
    {:noreply, close_editor(socket, todo)}
  end

  def handle_event("cancel_edit", _params, socket), do: {:noreply, socket}

  def handle_event("delete", %{"todo_id" => todo_id}, socket) do
    rows = Enum.sort_by(socket.assigns.todos ++ socket.assigns.checked_off, &{&1.position, &1.id})
    {_before, rest} = Enum.split_while(rows, &(&1.id != todo_id))

    socket =
      with [%Todo{} = todo | after_rows] <- rest,
           {:ok, _deleted} <- Todos.delete_todo(socket.assigns.current_scope, todo) do
        focus = delete_focus(List.first(after_rows), socket.assigns.editing, socket.assigns.form_key)
        socket |> load_todos() |> push_event("todos-focus", %{id: focus})
      else
        _missing_or_gone -> load_todos(socket)
      end

    {:noreply, socket}
  end

  attr :todo, Todo, required: true
  attr :row_marks, :string, required: true
  attr :target, :any, required: true
  attr :editing, :boolean, required: true
  attr :edit_changeset, :any, required: true

  defp todo_row(assigns) do
    url = assigns.todo.url

    assigns =
      assigns
      |> assign(:done, is_struct(assigns.todo.completed_at, DateTime))
      |> assign(:rail_link, not assigns.editing and is_binary(url) and String.starts_with?(url, "/"))
      |> assign(:outside_link, not assigns.editing and is_binary(url) and not String.starts_with?(url, "/"))
      |> assign(:show_text, not assigns.editing and is_nil(url))
      |> assign(:show_address, assigns.editing and is_binary(url))
      # A draft has no action, so the error waits for a refused save.
      |> assign(
        :show_edit_error,
        assigns.editing and assigns.edit_changeset.action == :update and assigns.edit_changeset.errors != []
      )

    ~H"""
    <li
      id={"todo-#{@todo.id}"}
      data-qa="todo_row"
      data-todo-row={@todo.id}
      class={[
        "group/todo relative flex items-start gap-3 px-3 py-2.5 rounded-lg",
        !@editing && "hover:bg-slate-100 dark:hover:bg-slate-800/70",
        @editing &&
          "bg-white dark:bg-slate-900/40 ring-1 ring-inset ring-slate-200 dark:ring-slate-700",
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
        :if={@show_text}
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
      <.form
        :let={f}
        :if={@editing}
        for={@edit_changeset}
        id={"todo-edit-form-#{@todo.id}"}
        data-qa="todo_edit_form"
        phx-change="edit_draft"
        phx-submit="save_edit"
        phx-target={@target}
        class="min-w-0 flex-1 -my-1.5"
      >
        <label for={"todo-edit-#{@todo.id}"} class="sr-only">Edit to-do</label>
        <textarea
          id={"todo-edit-#{@todo.id}"}
          name={f[:body].name}
          data-qa="todo_edit_body"
          data-todo-edit
          rows="1"
          maxlength="500"
          aria-invalid={@show_edit_error && "true"}
          aria-describedby={@show_edit_error && "todo-edit-#{@todo.id}-error"}
          phx-mounted={JS.focus() |> JS.dispatch("todos:caret-end")}
          phx-keydown="cancel_edit"
          phx-key="Escape"
          phx-target={@target}
          phx-debounce="300"
          phx-no-format
          class={[
            "block w-full resize-none field-sizing-content rounded-lg border bg-white dark:bg-slate-950/60 px-2.5 py-1.5 text-sm leading-5 text-slate-900 dark:text-slate-100 shadow-xs break-words [overflow-wrap:anywhere] focus:outline-none focus:ring-1",
            @show_edit_error && "border-red-400 focus:ring-red-400",
            !@show_edit_error &&
              "border-slate-300 dark:border-slate-600 focus:border-indigo-500 focus:ring-indigo-500"
          ]}
        >{f[:body].value}</textarea>
        <p
          :if={@show_edit_error}
          id={"todo-edit-#{@todo.id}-error"}
          role="alert"
          data-qa="todo_edit_error"
          class="mt-1.5 flex items-center gap-1 text-xs text-red-600 dark:text-red-400"
        >
          <.icon name="pi-warning-circle" class="h-3.5 w-3.5 shrink-0" />A to-do needs some text.
        </p>
        <p
          :if={@show_address}
          data-qa="todo_edit_address"
          class="mt-1.5 flex items-center gap-1 min-w-0 text-[11px] text-slate-500 dark:text-slate-400"
        >
          <.icon name="pi-link" class="h-3 w-3 shrink-0" /><span class="truncate font-mono">{@todo.url}</span>
          <span class="shrink-0">stays the same</span>
        </p>
        <div class="mt-2 flex items-center justify-end gap-1.5">
          <.button
            type="button"
            size="xs"
            variant="ghost"
            phx-click="cancel_edit"
            phx-target={@target}
            data-qa="todo_edit_cancel"
          >
            Cancel
          </.button>
          <.button type="submit" size="xs" variant="primary" data-qa="todo_edit_save">Save</.button>
        </div>
      </.form>
      <div
        :if={!@editing}
        class="-mr-1 flex items-center gap-0.5 shrink-0 opacity-0 group-hover/todo:opacity-100 group-focus-within/todo:opacity-100 pointer-coarse:opacity-100"
      >
        <button
          type="button"
          id={"todo-edit-button-#{@todo.id}"}
          data-qa="todo_edit"
          aria-label={"Edit: #{@todo.body}"}
          title="Edit"
          phx-click="edit"
          phx-value-todo_id={@todo.id}
          phx-target={@target}
          class="h-6 w-6 flex items-center justify-center rounded text-slate-500 dark:text-slate-400 hover:bg-slate-200 dark:hover:bg-slate-700 hover:text-slate-900 dark:hover:text-slate-100 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-blue-500"
        >
          <.icon name="pi-pencil-simple" class="h-[15px] w-[15px]" />
        </button>
        <button
          type="button"
          id={"todo-delete-#{@todo.id}"}
          data-qa="todo_delete"
          aria-label={"Delete: #{@todo.body}"}
          title="Delete"
          phx-click="delete"
          phx-value-todo_id={@todo.id}
          phx-target={@target}
          class="h-6 w-6 flex items-center justify-center rounded text-slate-500 dark:text-slate-400 hover:bg-red-500/10 hover:text-red-600 dark:hover:text-red-400 focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-red-500"
        >
          <.icon name="pi-trash" class="h-[15px] w-[15px]" />
        </button>
      </div>
    </li>
    """
  end

  defp close_editor(socket, %Todo{id: todo_id}) do
    socket
    |> assign(:editing, nil)
    |> push_event("todos-focus", %{id: "todo-edit-button-#{todo_id}"})
  end

  defp delete_focus(nil, _editing, form_key), do: "todo-body-#{form_key}"
  # The row being edited has no Delete, so the focus goes to its editor.
  defp delete_focus(%Todo{id: todo_id}, %Todo{id: todo_id}, _form_key), do: "todo-edit-#{todo_id}"
  defp delete_focus(%Todo{id: todo_id}, _editing, _form_key), do: "todo-delete-#{todo_id}"

  defp load_todos(socket) do
    %{current_scope: scope, time_zone: time_zone} = socket.assigns
    checked_off = if time_zone, do: Todos.list_todos(scope, checked_off_today: time_zone), else: []

    socket
    |> assign(:todos, Todos.list_todos(scope))
    |> assign(:checked_off, checked_off)
  end
end
