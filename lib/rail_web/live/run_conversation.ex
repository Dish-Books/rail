defmodule RailWeb.Live.RunConversation do
  @moduledoc """
  One task's conversation with its agents, and the composer that talks to them.

  Which run is being read, what is typed into the box, whether the raw log is
  showing — none of it means anything outside this view, so it lives here rather
  than on the page. What the page still owns is the subscription: a LiveComponent
  cannot subscribe, so new log lines arrive through `send_update/3`.
  """
  use RailWeb, :live_component

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  @doc """
  Takes the task and its runs; everything else the conversation decides itself.

  `stage_run` is the run for the stage the task sits at. The conversation opens
  on it, and follows it when the task moves to another stage; in between, the
  human's own pick of a run stays put.

  `appended_events` may arrive on their own from the page's `run:<id>`
  subscriptions, tagged with the run they belong to, in which case only the log
  of that run is extended, and only if it is the one being read.
  """
  # A send reloads the log from the database, and the broadcast for the lines it
  # just wrote can land after that, so lines already held are dropped.
  @impl true
  def update(%{appended_events: events, run_id: run_id}, socket) do
    case socket.assigns.selected_run do
      %Run{id: ^run_id} ->
        held = MapSet.new(socket.assigns.run_events, & &1.id)
        fresh = Enum.reject(events, &MapSet.member?(held, &1.id))
        {:ok, assign_run_events(socket, socket.assigns.run_events ++ fresh)}

      _other_run ->
        {:ok, socket}
    end
  end

  def update(assigns, socket) do
    socket = assign_defaults(socket)
    runs = sort_runs(assigns.runs)
    stage_run = assigns[:stage_run]
    stage_run_id = stage_run && stage_run.id

    selected_run =
      if stage_run_id == socket.assigns.stage_run_id,
        do: pick_run(runs, socket.assigns.selected_run),
        else: pick_run(runs, stage_run)

    socket =
      socket
      |> assign(assigns)
      |> assign(:runs, runs)
      |> assign(:stage_run_id, stage_run_id)
      |> assign(:selected_run, selected_run)
      |> assign_run_events(load_run_events(selected_run))

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :has_runs, assigns.runs != [])

    ~H"""
    <div
      id="conversation-tab-root"
      data-qa="conversation-tab"
      class="flex flex-col flex-1 min-h-0"
    >
      <%= if not @has_runs do %>
        <!-- 4.1 Empty State: No role has run this task yet -->
        <div
          id="conversation-empty-state"
          data-qa="conversation_empty_state"
          class="flex flex-1 items-center justify-center min-h-[300px] text-center p-8"
        >
          <p class="text-sm font-medium text-slate-500 dark:text-slate-400">
            No role has run this task yet.
          </p>
        </div>
      <% else %>
        <div class="flex flex-col flex-1 min-h-0">
          <!-- 4.3 Role Selector Row: the run being read, with the others beside it -->
          <div
            id="role-selector-row"
            data-qa="role-selector-row"
            class="flex items-center flex-wrap gap-x-3 gap-y-2 px-5 py-4 border-b border-slate-200 dark:border-slate-700"
          >
            <%= for run <- @runs do %>
              <% role = resolve_role(run.role_id, @roles_map) %>
              <% is_selected = @selected_run != nil and @selected_run.id == run.id %>
              <button
                type="button"
                id={"role-chip-#{run.role_id}"}
                data-qa={"role-chip-#{run.role_id}"}
                phx-click="select_role"
                phx-target={@myself}
                phx-value-role_id={run.role_id}
                class={[
                  "inline-flex items-center gap-2 text-sm font-semibold transition-colors cursor-pointer",
                  is_selected && "text-slate-900 dark:text-slate-100",
                  not is_selected &&
                    "text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100"
                ]}
              >
                <span class={[
                  "h-2 w-2 rounded-full shrink-0",
                  Run.running?(run) && "bg-green-500",
                  not Run.running?(run) && "bg-slate-400 dark:bg-slate-500"
                ]} />
                <span>{role.name}</span>
              </button>
            <% end %>

            <span
              :if={@selected_run}
              id={"elapsed-run-#{@selected_run.id}"}
              phx-hook="Elapsed"
              data-started-at={
                Run.running?(@selected_run) && format_started_at(@selected_run.started_at)
              }
              data-elapsed-seconds={!Run.running?(@selected_run) && elapsed_seconds(@selected_run)}
              data-qa="elapsed-text"
              class="ml-auto font-mono text-xs text-slate-500 dark:text-slate-400"
            >
              {format_elapsed_run(@selected_run)}
            </span>
          </div>

          <!-- Transcript Area: Raw Log vs ChatPane -->
          <div class="flex flex-col flex-1 min-h-0">
            <%= if @show_raw_log do %>
              <!-- 4.13 Raw Log View -->
              <.raw_log_view
                run={@selected_run}
                log_lines={@log_lines}
                runs={@runs}
                roles_map={@roles_map}
                target={@myself}
              />
            <% else %>
              <!-- 4.7 - 4.12 ChatPane Layout & Composer -->
              <.chat_pane
                task={@task}
                run={@selected_run}
                role={selected_role(@selected_run, @roles_map)}
                turns={@turns}
                expanded_activities={@expanded_activities}
                runs={@runs}
                roles_map={@roles_map}
                target={@myself}
              />
            <% end %>
          </div>

          <!-- 4.4 Run Metadata Row -->
          <div
            id="run-metadata-row"
            data-qa="run-metadata-row"
            class="flex items-center flex-wrap gap-x-1.5 gap-y-1 px-5 py-3 font-mono text-xs text-slate-500 dark:text-slate-400"
          >
            <span :if={@selected_run} id="metadata-run-status">
              {format_run_status(@selected_run.status)} ·
            </span>

            <span :if={@selected_run && Run.usage(@selected_run)} id="metadata-run-usage">
              {Run.usage(@selected_run)} ·
            </span>

            <span
              :if={@selected_run && @selected_run.conversation_id not in [nil, ""]}
              id="metadata-run-conversation-id"
              title={@selected_run.conversation_id}
              class="select-text truncate max-w-[10rem]"
            >
              {"conversation #{@selected_run.conversation_id}"} ·
            </span>

            <button
              type="button"
              id="toggle-raw-log"
              data-qa="toggle-raw-log"
              phx-click="toggle_raw_log"
              phx-target={@myself}
              class="font-semibold text-blue-600 dark:text-blue-400 hover:underline cursor-pointer"
            >
              {if @show_raw_log, do: "Show chat", else: "Raw log"}
            </button>
          </div>

          <.composer
            :if={not @show_raw_log}
            task={@task}
            run={@selected_run}
            role={selected_role(@selected_run, @roles_map)}
            chat_input={@chat_input}
            chat_sending={@chat_sending}
            target={@myself}
          />
        </div>
      <% end %>
    </div>
    """
  end

  # --- ChatPane Component ---

  attr :task, :any, required: true
  attr :run, :any, required: true
  attr :role, :any, required: true
  attr :turns, :list, default: []
  attr :expanded_activities, MapSet, required: true
  attr :runs, :list, default: []
  attr :roles_map, :map, default: %{}
  attr :target, :any, required: true

  def chat_pane(assigns) do
    assigns =
      assigns
      |> assign(:messages, assigns.turns)
      |> assign(:has_messages, assigns.turns != [])

    ~H"""
    <div id="chat-pane-root" data-qa="chat-pane" class="flex flex-col flex-1 min-h-[400px]">
      <!-- Messages List / Empty State with Autoscroll Hook -->
      <div
        id="chat-messages"
        data-qa="chat-messages"
        phx-hook="ChatAutoscroll"
        class="flex-1 overflow-y-auto px-5 py-5 space-y-4"
      >
        <%= if not @has_messages do %>
          <!-- Empty State -->
          <div
            id="chat-empty-state"
            data-qa="chat-empty-state"
            class="flex items-center justify-center h-48 text-center"
          >
            <p class="text-sm font-medium text-slate-500 dark:text-slate-400">
              No messages yet.
            </p>
          </div>
        <% else %>
          <%= for {msg, idx} <- Enum.with_index(@messages) do %>
            <.message_item
              msg={msg}
              idx={idx}
              role={@role}
              runs={@runs}
              roles_map={@roles_map}
              expanded_activities={@expanded_activities}
              worktree_path={@task.worktree_path}
              target={@target}
            />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # --- Message Item Subcomponent ---

  attr :msg, :any, required: true
  attr :idx, :integer, required: true
  attr :role, :any, required: true
  attr :runs, :list, default: []
  attr :roles_map, :map, default: %{}
  attr :expanded_activities, MapSet, required: true
  attr :worktree_path, :string, required: true
  attr :target, :any, required: true

  def message_item(assigns) do
    msg = assigns.msg

    assigns =
      assigns
      |> assign(:author, msg.author)
      |> assign(:text, msg.content || "")

    ~H"""
    <%= case @author do %>
      <% :human -> %>
        <!-- 4.8 _HumanBubble (right-aligned, plain selectable text, NOT markdown) -->
        <div
          id={"msg-#{@idx}"}
          data-qa="human-bubble"
          class="w-fit max-w-[85%] ml-auto mt-3.5 px-3 py-2 rounded-xl rounded-br-xs bg-slate-100 dark:bg-slate-800 border border-slate-200 dark:border-slate-700 text-slate-800 dark:text-slate-100 space-y-1"
        >
          <div class="flex items-center gap-1 text-[11px] font-semibold text-slate-500 dark:text-slate-400">
            <.icon name="pi-user" class="h-3 w-3 shrink-0" />
            <span>You</span>
          </div>
          <%!-- Kept on one line: pre-wrap would render the template's own indentation. --%>
          <div
            phx-no-format
            class="text-[13px] whitespace-pre-wrap wrap-break-word select-text leading-relaxed"
          >{String.trim(@text)}</div>
        </div>
      <% :role -> %>
        <!-- 4.8 _RoleBubble (unframed markdown: the sidebar already says who is talking) -->
        <div
          id={"msg-#{@idx}"}
          data-qa="role-bubble"
          class="text-slate-900 dark:text-slate-100"
        >
          <div class="select-text prose dark:prose-invert max-w-none text-[13px] leading-relaxed">
            <.markdown content={@text} />
          </div>
        </div>
      <% :activity -> %>
        <!-- 4.8 _ActivityTile (collapsible tool activity) -->
        <% expanded = MapSet.member?(@expanded_activities, @idx) %>
        <% steps = tool_steps(@text, @worktree_path) %>
        <% error_count = Enum.count(steps, & &1.error?) %>
        <div
          id={"activity-tile-#{@idx}"}
          data-qa="activity-tile"
          class="max-w-[720px] rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 overflow-hidden"
        >
          <button
            type="button"
            phx-click="toggle_activity"
            phx-target={@target}
            phx-value-index={@idx}
            class="w-full flex items-center gap-2 px-3 py-2 text-xs text-slate-500 dark:text-slate-400 hover:bg-slate-50 dark:hover:bg-slate-800 transition-colors cursor-pointer text-left"
          >
            <.icon name="pi-wrench" class="h-3.5 w-3.5 shrink-0" />
            <span class="font-medium text-slate-700 dark:text-slate-300 shrink-0">
              {if length(steps) == 1,
                do: "Tool activity (1 step)",
                else: "Tool activity (#{length(steps)} steps)"}
            </span>
            <span class="truncate">{tool_names_summary(steps)}</span>
            <span
              :if={error_count > 0}
              class="inline-flex items-center gap-1 shrink-0 text-red-600 dark:text-red-400"
            >
              <.icon name="pi-warning-circle" class="h-3.5 w-3.5" />
              {error_count}
            </span>
            <.icon
              name={if expanded, do: "pi-caret-up", else: "pi-caret-down"}
              class="h-4 w-4 shrink-0 ml-auto"
            />
          </button>

          <ul
            :if={expanded}
            id={"activity-content-#{@idx}"}
            data-qa="activity-content"
            class="border-t border-slate-200 dark:border-slate-700 divide-y divide-slate-100 dark:divide-slate-800 select-text"
          >
            <li
              :for={step <- steps}
              data-qa="activity-step"
              class={[
                "flex items-start gap-2 px-3 py-1.5 text-xs",
                step.error? &&
                  "border-l-2 border-l-red-500 text-red-700 dark:text-red-300"
              ]}
            >
              <%= if step.error? do %>
                <.icon name="pi-warning-circle" class="h-3.5 w-3.5 shrink-0 mt-px" />
                <div class="min-w-0 flex-1 space-y-0.5">
                  <div :if={step.name} class="font-medium">{step.name}</div>
                  <%!-- Kept on one line: pre-wrap would render the template's own indentation. --%>
                  <p
                    phx-no-format
                    title={step.detail}
                    class="font-mono text-[11px] whitespace-pre-wrap wrap-break-word line-clamp-6 text-red-600/90 dark:text-red-300/90"
                  >{String.trim(step.detail)}</p>
                </div>
              <% else %>
                <.icon
                  name={tool_icon(step.name)}
                  class="h-3.5 w-3.5 shrink-0 mt-px text-slate-400 dark:text-slate-500"
                />
                <span :if={step.name} class="font-medium shrink-0 text-slate-900 dark:text-slate-100">
                  {step.name}
                </span>
                <span
                  title={step.detail}
                  class="font-mono min-w-0 truncate text-slate-500 dark:text-slate-400"
                >
                  {step.detail}
                </span>
              <% end %>
            </li>
          </ul>
        </div>
      <% :event -> %>
        <!-- 4.8 _EventTile -->
        <%= if String.starts_with?(@text, "[rail]") do %>
          <div
            id={"msg-#{@idx}"}
            data-qa="rail-event"
            class="flex items-center gap-2 px-2.5 py-1.5 rounded-md bg-blue-500/10 border border-blue-500/30 text-blue-700 dark:text-blue-300 font-mono text-[11px] my-1"
          >
            <.icon name="pi-info" class="h-3.5 w-3.5 shrink-0" />
            <span class="select-text">{@text}</span>
          </div>
        <% else %>
          <div
            id={"msg-#{@idx}"}
            data-qa="system-event"
            class="text-center font-mono text-[11px] text-slate-500 dark:text-slate-400 select-text my-0.5"
          >
            {@text}
          </div>
        <% end %>
    <% end %>
    """
  end

  # --- Composer Component ---

  attr :task, :any, required: true
  attr :run, :any, required: true
  attr :role, :any, required: true
  attr :chat_input, :string, default: ""
  attr :chat_sending, :boolean, default: false
  attr :target, :any, required: true

  def composer(assigns) do
    role = assigns.role
    run = assigns.run

    role_id = if is_map(role), do: Map.get(role, :id)
    role_name = if is_map(role), do: Map.get(role, :name, "role"), else: "role"

    is_thinking = Run.running?(run)
    is_queued = run != nil and is_binary(run.pending_chat) and run.pending_chat != ""
    is_unavailable = run == nil or not Run.can_chat?(run)

    hint_text =
      cond do
        is_unavailable -> "Chat unavailable"
        is_queued -> "Add to queued message..."
        is_thinking -> "Message #{role_name}..."
        true -> "Message #{role_name}..."
      end

    assigns =
      assigns
      |> assign(:role_id, role_id)
      |> assign(:role_name, role_name)
      |> assign(:is_thinking, is_thinking)
      |> assign(:is_queued, is_queued)
      |> assign(:is_unavailable, is_unavailable)
      |> assign(:hint_text, hint_text)

    ~H"""
    <div
      id="composer-root"
      data-qa="composer chat-composer"
      class="p-4 border-t border-slate-200 dark:border-slate-700"
    >
      <!-- Thinking and queued stack: a message typed mid-turn waits behind it. -->
      <div
        :if={@is_thinking}
        id="thinking-banner"
        data-qa="thinking-banner"
        class="flex items-center justify-between gap-2 px-3 py-2 rounded-lg bg-blue-100 dark:bg-blue-900/30 border border-blue-600 dark:border-blue-500/20 mb-3"
      >
        <div class="flex items-center gap-2 text-xs font-bold text-blue-600 dark:text-blue-500">
          <svg class="animate-spin h-3.5 w-3.5" viewBox="0 0 24 24" fill="none">
            <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="3" />
            <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z" />
          </svg>
          <span>{"#{@role_name} is thinking..."}</span>
        </div>

        <button
          type="button"
          id="stop-run"
          data-qa="stop-run"
          phx-click="stop_run"
          phx-target={@target}
          class="inline-flex items-center gap-1 px-2.5 py-1 rounded text-xs font-semibold text-red-600 dark:text-red-500 hover:bg-red-100 dark:hover:bg-red-900/30 transition-colors cursor-pointer"
        >
          <.icon name="pi-stop-fill" class="h-3.5 w-3.5 shrink-0" />
          <span>Stop</span>
        </button>
      </div>

      <div
        :if={@is_queued}
        id="queued-banner"
        data-qa="queued-banner"
        class="flex items-center justify-between gap-2 px-3 py-2 rounded-lg bg-slate-100 dark:bg-slate-700 border border-slate-300 dark:border-slate-600 mb-3"
      >
        <div class="flex items-center gap-2 text-xs text-slate-900 dark:text-slate-100 truncate">
          <.icon name="pi-clock" class="h-4 w-4 shrink-0 text-slate-500 dark:text-slate-400" />
          <span class="truncate">
            {"Queued: \"#{@run.pending_chat}\" (sends when #{@role_name} is done)"}
          </span>
        </div>

        <div class="flex items-center gap-1 shrink-0">
          <button
            :if={@is_thinking}
            type="button"
            id="send-queued-now"
            data-qa="send-queued-now"
            phx-click="stop_and_send_message"
            phx-target={@target}
            class="px-2.5 py-1 rounded text-xs font-semibold text-blue-600 dark:text-blue-500 hover:bg-blue-100 dark:hover:bg-blue-900/30 transition-colors cursor-pointer"
          >
            Send now
          </button>

          <button
            type="button"
            id="cancel-queued-message"
            data-qa="cancel-queued-message"
            phx-click="stop_run"
            phx-target={@target}
            class="px-2.5 py-1 rounded text-xs font-semibold text-slate-500 dark:text-slate-400 hover:text-slate-900 dark:hover:text-slate-100 hover:bg-slate-200 dark:hover:bg-slate-600 transition-colors cursor-pointer"
          >
            Cancel
          </button>
        </div>
      </div>

      <div
        :if={@is_unavailable}
        id="unavailable-banner"
        data-qa="unavailable-banner"
        class="flex items-center gap-2 px-3 py-2 rounded-lg bg-slate-200 dark:bg-slate-600 text-xs text-slate-500 dark:text-slate-400 mb-3"
      >
        <.icon name="pi-info" class="h-4 w-4 shrink-0" />
        <span>{"Cannot chat with #{@role_name} yet: the role has not started a conversation."}</span>
      </div>

      <!-- Input Row (Enter sends) -->
      <form
        id="chat-composer-form"
        phx-submit="send_chat"
        phx-change="chat_input_change"
        phx-target={@target}
        class="flex items-center gap-2"
      >
        <input type="hidden" name="role_id" value={@role_id} />
        <input
          type="text"
          id="chat-input"
          name="message"
          data-qa="chat-input"
          value={@chat_input}
          placeholder={@hint_text}
          disabled={@is_unavailable or @chat_sending}
          autocomplete="off"
          phx-debounce="300"
          class="flex-1 px-3 py-2 text-xs sm:text-sm rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500 disabled:opacity-50 disabled:cursor-not-allowed"
        />

        <button
          type="submit"
          id="chat-send-button"
          data-qa="chat-submit chat-send-button"
          disabled={@is_unavailable or @chat_sending}
          class="inline-flex items-center justify-center h-9 w-9 rounded-lg bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed transition-opacity shrink-0 cursor-pointer shadow-xs"
        >
          <%= if @chat_sending do %>
            <svg class="animate-spin h-4 w-4" viewBox="0 0 24 24" fill="none">
              <circle
                class="opacity-25"
                cx="12"
                cy="12"
                r="10"
                stroke="currentColor"
                stroke-width="3"
              />
              <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z" />
            </svg>
          <% else %>
            <.icon name="pi-paper-plane-tilt" class="h-4 w-4 shrink-0" />
          <% end %>
        </button>
      </form>
    </div>
    """
  end

  # --- Raw Log View ---

  attr :run, :any, required: true
  attr :log_lines, :list, default: []
  attr :runs, :list, default: []
  attr :roles_map, :map, default: %{}
  attr :target, :any, required: true

  def raw_log_view(assigns) do
    lines = assigns.log_lines || []

    assigns =
      assigns
      |> assign(:lines, lines)
      |> assign(:has_lines, lines != [])

    ~H"""
    <div
      id="raw-log-container"
      data-qa="raw_log_container"
      phx-hook="ChatAutoscroll"
      class="w-full flex-1 min-h-[400px] p-4 bg-zinc-950 text-zinc-300 font-mono text-xs overflow-y-auto select-text"
    >
      <%= if not @has_lines do %>
        <div id="raw-log-empty-state" class="flex items-center justify-center h-48 text-zinc-500">
          <p>Nothing logged yet.</p>
        </div>
      <% else %>
        <%= for {line, idx} <- Enum.with_index(@lines) do %>
          <div
            id={"raw-log-line-#{idx}"}
            data-qa="raw-log-line"
            class={["leading-relaxed whitespace-pre-wrap", raw_log_color_class(line)]}
          >
            {line}
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("select_role", %{"role_id" => role_id}, socket) do
    case Enum.find(socket.assigns.runs, &(&1.role_id == role_id)) do
      %Run{} = run -> {:noreply, select(socket, run)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("toggle_raw_log", _params, socket) do
    {:noreply, assign(socket, :show_raw_log, not socket.assigns.show_raw_log)}
  end

  def handle_event("toggle_activity", %{"index" => index}, socket) do
    index = String.to_integer(index)
    expanded = socket.assigns.expanded_activities

    expanded =
      if MapSet.member?(expanded, index), do: MapSet.delete(expanded, index), else: MapSet.put(expanded, index)

    {:noreply, assign(socket, :expanded_activities, expanded)}
  end

  def handle_event("chat_input_change", params, socket) do
    {:noreply, assign(socket, :chat_input, Map.get(params, "message") || "")}
  end

  def handle_event("send_chat", params, socket) do
    message = Map.get(params, "message") || socket.assigns.chat_input

    {:noreply, send_chat(socket, socket.assigns.selected_run, message)}
  end

  # Stopping hands back whatever had not been delivered, and the composer is where
  # it belongs: still the human's to edit, re-send or throw away.
  def handle_event("stop_run", _params, socket) do
    {:ok, run, queued} = Pipeline.stop_run(socket.assigns.selected_run)

    socket =
      socket
      |> assign(:chat_input, restore_draft(queued, socket.assigns.chat_input))
      |> select(run)

    {:noreply, socket}
  end

  def handle_event("stop_and_send_message", _params, socket) do
    run = socket.assigns.selected_run
    _sent = Pipeline.stop_and_send_message(run)
    {:noreply, select(socket, run)}
  end

  # --- Private Helpers ---

  defp send_chat(socket, %Run{} = run, message) do
    if String.trim(message) == "" or socket.assigns.chat_sending do
      socket
    else
      case Pipeline.send_message(run, message) do
        {:ok, _delivery, run} -> socket |> assign(:chat_input, "") |> select(run)
        {:error, _reason} -> socket
      end
    end
  end

  defp select(socket, %Run{} = run) do
    run = run.id |> Pipeline.get_run() |> elem(1) |> Kernel.||(run)

    socket
    |> assign(:selected_run, run)
    |> assign(:runs, replace_run(socket.assigns.runs, run))
    |> assign_run_events(load_run_events(run))
  end

  defp replace_run(runs, %Run{id: id} = run) do
    Enum.map(runs, fn existing -> if existing.id == id, do: %{run | role: existing.role}, else: existing end)
  end

  defp assign_defaults(socket) do
    socket
    |> assign_new(:selected_run, fn -> nil end)
    |> assign_new(:stage_run_id, fn -> nil end)
    |> assign_new(:show_raw_log, fn -> false end)
    |> assign_new(:expanded_activities, fn -> MapSet.new() end)
    |> assign_new(:chat_input, fn -> "" end)
    |> assign_new(:chat_sending, fn -> false end)
    |> assign_new(:run_events, fn -> [] end)
  end

  # The log the component holds; the rendered lines and the turns read out of it
  # are both derived from it, so an appended batch only updates one list. The log
  # is what the agent's CLI wrote, so its backend reads it into lines before they
  # read as a conversation; lines Rail wrote itself pass through as they are.
  defp assign_run_events(socket, run_events) do
    lines = Enum.map(run_events, & &1.line)

    socket
    |> assign(:run_events, run_events)
    |> assign(:log_lines, lines)
    |> assign(:turns, lines |> readable_lines(socket.assigns) |> Pipeline.parse_transcript())
  end

  defp readable_lines(lines, %{selected_run: %Run{role_id: role_id}, roles_map: %{} = roles_map}) do
    case roles_map do
      %{^role_id => %{backend: %Backend{} = backend}} -> Tools.parse_stream(backend, lines).logs
      _unknown_backend -> lines
    end
  end

  defp readable_lines(lines, _no_run), do: lines

  defp load_run_events(%Run{} = run), do: Pipeline.list_run_events(run)
  defp load_run_events(_no_run), do: []

  # The run the human was reading stays selected across a refresh; otherwise the
  # most recent one is what they want to see.
  defp pick_run(runs, %Run{id: id}), do: Enum.find(runs, &(&1.id == id)) || List.last(runs)
  defp pick_run(runs, nil), do: List.last(runs)

  defp sort_runs(runs) do
    Enum.sort_by(runs, &{&1.started_at || &1.inserted_at, &1.inserted_at, &1.id})
  end

  defp selected_role(%Run{role_id: role_id}, roles_map), do: resolve_role(role_id, roles_map)

  defp restore_draft(nil, draft), do: draft
  defp restore_draft(queued, draft) when draft in [nil, ""], do: queued
  defp restore_draft(queued, draft), do: "#{queued}\n\n#{draft}"

  defp resolve_role(role_id, roles_map) do
    if is_map(roles_map) and Map.has_key?(roles_map, role_id) do
      role = Map.get(roles_map, role_id)
      %{id: role_id, name: role.name, icon_name: Map.get(role, :icon_name, "pi-terminal-window")}
    else
      %{id: role_id, name: format_role_id(role_id), icon_name: "pi-terminal-window"}
    end
  end

  defp format_role_id(role_id) do
    role_id
    |> to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_started_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_elapsed_run(%Run{} = run), do: run |> elapsed_seconds() |> format_duration()

  # A run that stopped without a completion time has no end to measure to, so it
  # reads as when it last changed.
  defp elapsed_seconds(%Run{started_at: %DateTime{} = started} = run) do
    ended = if Run.running?(run), do: DateTime.utc_now(), else: run.completed_at || run.updated_at || DateTime.utc_now()
    max(0, DateTime.diff(ended, started, :second))
  end

  # An activity turn is `[tool] Name summary` lines, as the backends write them,
  # with `[tool error] detail` where a call failed. Older logs name the tool in
  # the bracket instead: `[tool read_file] summary`.
  defp tool_steps(text, worktree_path) do
    text
    |> to_string()
    |> String.split("\n", trim: true)
    |> Enum.map(&tool_step(&1, worktree_path))
  end

  defp tool_step(line, worktree_path) do
    case Regex.run(~r/^\[tool( error)?(?: ([^\]]+))?\]\s*(.*)$/s, line) do
      [_line, error, "", rest] when error != "" -> %{name: nil, detail: rest, error?: true}
      [_line, error, "", rest] -> rest |> split_tool_name() |> step(error != "", worktree_path)
      [_line, error, name, rest] -> step({name, rest}, error != "", worktree_path)
      nil -> %{name: nil, detail: line, error?: false}
    end
  end

  defp split_tool_name(rest) do
    case String.split(rest, " ", parts: 2) do
      [name, detail] -> {name, detail}
      [name] -> {name, ""}
    end
  end

  defp step({name, detail}, error?, worktree_path) do
    %{name: name, detail: relative_to(detail, worktree_path), error?: error?}
  end

  # Paths inside the task's worktree read shorter from its root.
  defp relative_to(detail, worktree_path) do
    String.replace(detail, String.trim_trailing(worktree_path, "/") <> "/", "")
  end

  # Which tools ran, in the order they first ran, with how many times each did.
  defp tool_names_summary(steps) do
    names = steps |> Enum.map(& &1.name) |> Enum.reject(&is_nil/1)
    counts = Enum.frequencies(names)

    names
    |> Enum.uniq()
    |> Enum.map_join(", ", fn name ->
      if counts[name] == 1, do: name, else: "#{name} ×#{counts[name]}"
    end)
  end

  defp tool_icon(name) do
    case name |> to_string() |> String.downcase() do
      n when n in ["read", "read_file", "view_file"] ->
        "pi-file-text"

      n when n in ["write", "edit", "multiedit", "notebookedit", "write_to_file", "replace_file_content"] ->
        "pi-pencil-simple"

      n when n in ["bash", "run_command", "runcommand"] ->
        "pi-terminal-window"

      n when n in ["grep", "glob", "grep_search", "find_by_name"] ->
        "pi-magnifying-glass"

      n when n in ["webfetch", "websearch", "fetch_url", "read_url_content"] ->
        "pi-globe"

      n when n in ["task", "agent"] ->
        "pi-robot"

      n when n in ["todowrite"] ->
        "pi-list-checks"

      _other ->
        "pi-wrench"
    end
  end

  defp raw_log_color_class(line) do
    cond do
      String.starts_with?(line, ["[error", "[stderr", "[denied"]) ->
        "text-red-400"

      String.starts_with?(line, "[tool") ->
        "text-cyan-300"

      String.starts_with?(line, ["[human", "[USER_ANSWER"]) ->
        "text-amber-300"

      String.starts_with?(line, ["[rail", "[run", "[init", "[result", "[reattach"]) ->
        "text-green-400"

      true ->
        "text-zinc-300"
    end
  end
end
