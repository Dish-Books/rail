defmodule RailWeb.Live.RunConversation do
  @moduledoc """
  One task's conversation with its agents, and the composer that talks to them.

  Which run is being read, what is typed into the box, whether the raw log is
  showing — none of it means anything outside this view, so it lives here rather
  than on the page. What the page still owns is the subscription: a LiveComponent
  cannot subscribe, so new log lines arrive through `send_update/3`.
  """
  use RailWeb, :live_component

  import RailWeb.CoreComponents, only: [icon: 1, markdown: 1]

  alias Rail.Domain.ChatTranscript
  alias Rail.Domain.HandoffLine
  alias Rail.Domain.TaskUsage
  alias Rail.Pipeline
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run

  @doc """
  Takes the task and its runs; everything else the conversation decides itself.

  `run_events` may arrive on its own from the page's `run:<id>` subscription, in
  which case only the log is replaced.
  """
  @impl true
  def update(%{appended_events: events}, socket) do
    {:ok, assign_run_events(socket, socket.assigns.run_events ++ events)}
  end

  def update(assigns, socket) do
    socket = assign_defaults(socket)
    runs = sort_runs(assigns.runs)
    selected_run = pick_run(runs, socket.assigns.selected_run)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:runs, runs)
     |> assign(:selected_run, selected_run)
     |> assign_run_events(load_run_events(selected_run))}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :has_runs, assigns.runs != [])

    ~H"""
    <div id="conversation-tab-root" data-qa="conversation-tab" class="space-y-4">
      <%= if not @has_runs do %>
        <!-- 4.1 Empty State: No role has run this task yet -->
        <div
          id="conversation-empty-state"
          data-qa="conversation_empty_state"
          class="flex items-center justify-center min-h-[300px] text-center p-8 bg-white dark:bg-slate-900 rounded-xl border border-slate-200 dark:border-slate-700 shadow-xs"
        >
          <p class="text-sm font-medium text-slate-500 dark:text-slate-400">
            No role has run this task yet.
          </p>
        </div>
      <% else %>
        <div class="rounded-xl border border-slate-200 bg-slate-50 dark:border-slate-700 dark:bg-slate-800 overflow-hidden divide-y divide-slate-200 dark:divide-slate-700">
          <!-- 4.3 Role Selector Row -->
          <div
            id="role-selector-row"
            data-qa="role-selector-row"
            class="flex items-center justify-between flex-wrap gap-2 px-6 pt-4 pb-3"
          >
            <!-- Choice Chips of Ordered Runs -->
            <div class="flex items-center flex-wrap gap-2">
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
                    "inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold transition-colors cursor-pointer border",
                    is_selected &&
                      "bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 border-blue-600 dark:border-blue-500 shadow-xs",
                    not is_selected &&
                      "bg-slate-100 dark:bg-slate-700 text-slate-900 dark:text-slate-100 border-slate-300 dark:border-slate-600 hover:bg-slate-200 dark:hover:bg-slate-600"
                  ]}
                >
                  <.icon name={role.icon_name} class="h-4 w-4 shrink-0" />
                  <span>{role.name}</span>
                </button>
              <% end %>
            </div>

            <!-- Trailing Toggle Button: Raw Log vs Show Chat -->
            <button
              type="button"
              id="toggle-raw-log"
              data-qa="toggle-raw-log"
              phx-click="toggle_raw_log"
              phx-target={@myself}
              class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-slate-500 dark:border-slate-400 text-xs font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-100 dark:hover:bg-slate-700 transition-colors cursor-pointer shrink-0 ml-auto"
            >
              <.icon
                name={if @show_raw_log, do: "pi-chat-circle", else: "pi-terminal-window"}
                class="h-4 w-4 shrink-0"
              />
              <span>{if @show_raw_log, do: "Show chat", else: "Raw log"}</span>
            </button>
          </div>

          <!-- 4.4 Run Metadata Row -->
          <div
            :if={@selected_run}
            id="run-metadata-row"
            data-qa="run-metadata-row"
            class="flex items-center flex-wrap gap-4 px-6 py-2.5 text-xs text-slate-500 dark:text-slate-400 bg-slate-50 dark:bg-slate-800"
          >
            <!-- 1. selected.status name in lowerCamel -->
            <span id="metadata-run-status" class="font-mono font-semibold">
              {format_run_status(@selected_run.status)}
            </span>

            <!-- 2. ElapsedTimeText -->
            <span
              id={"elapsed-run-#{@selected_run.id}"}
              phx-hook="Elapsed"
              data-started-at={format_started_at(@selected_run.started_at)}
              data-qa="elapsed-text"
              class="font-mono"
            >
              {format_elapsed_run(@selected_run)}
            </span>

            <!-- 4. Usage describe -->
            <span :if={has_usage?(@selected_run.usage)} id="metadata-run-usage">
              {TaskUsage.describe(@selected_run.usage)}
            </span>

            <!-- 5. Selectable conversation id -->
            <span
              :if={is_binary(@selected_run.conversation_id) and @selected_run.conversation_id != ""}
              id="metadata-run-conversation-id"
              class="font-mono select-text"
            >
              {"conversation #{@selected_run.conversation_id}"}
            </span>
          </div>

          <!-- Transcript Area: Raw Log vs ChatPane -->
          <div>
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
                transcript={@transcript}
                expanded_activities={@expanded_activities}
                runs={@runs}
                roles_map={@roles_map}
                chat_input={@chat_input}
                chat_sending={@chat_sending}
                target={@myself}
              />
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # --- ChatPane Component ---

  attr :task, :any, required: true
  attr :run, :any, required: true
  attr :role, :any, required: true
  attr :transcript, :any, required: true
  attr :expanded_activities, :any, default: []
  attr :runs, :list, default: []
  attr :roles_map, :map, default: %{}
  attr :chat_input, :string, default: ""
  attr :chat_sending, :boolean, default: false
  attr :target, :any, required: true

  def chat_pane(assigns) do
    messages =
      if assigns.transcript, do: assigns.transcript.messages || assigns.transcript.turns || [], else: []

    assigns =
      assigns
      |> assign(:messages, messages)
      |> assign(:has_messages, messages != [])

    ~H"""
    <div id="chat-pane-root" data-qa="chat-pane" class="flex flex-col min-h-[400px]">
      <!-- Messages List / Empty State with Autoscroll Hook -->
      <div
        id="chat-messages"
        data-qa="chat-messages"
        phx-hook="ChatAutoscroll"
        class="flex-1 overflow-y-auto p-4 space-y-3 max-h-[560px]"
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
              target={@target}
            />
          <% end %>
        <% end %>
      </div>

      <!-- Pinned Composer at Bottom -->
      <.composer
        task={@task}
        run={@run}
        role={@role}
        chat_input={@chat_input}
        chat_sending={@chat_sending}
        target={@target}
      />
    </div>
    """
  end

  # --- Message Item Subcomponent ---

  attr :msg, :any, required: true
  attr :idx, :integer, required: true
  attr :role, :any, required: true
  attr :runs, :list, default: []
  attr :roles_map, :map, default: %{}
  attr :expanded_activities, :any, default: []
  attr :target, :any, required: true

  def message_item(assigns) do
    msg = assigns.msg
    author = msg.author || msg.role

    assigns =
      assigns
      |> assign(:author, author)
      |> assign(:text, msg.text || msg.content || "")
      |> assign(:handoff, msg.handoff)

    ~H"""
    <%= case @author do %>
      <% a when a in [:human, :user] -> %>
        <!-- 4.8 _HumanBubble (right-aligned, plain selectable text, NOT markdown) -->
        <div
          id={"msg-#{@idx}"}
          data-qa="human-bubble"
          class="max-w-[600px] ml-auto p-3 rounded-tl-xl rounded-tr-xl rounded-bl-xl rounded-br-xs bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200 space-y-1.5 shadow-xs"
        >
          <div class="flex items-center gap-1.5 text-xs font-bold">
            <.icon name="pi-user" class="h-3.5 w-3.5 shrink-0" />
            <span>You</span>
          </div>
          <div class="text-[13px] whitespace-pre-wrap select-text leading-relaxed">
            {@text}
          </div>
        </div>
      <% a when a in [:role, :agent] -> %>
        <!-- 4.8 _RoleBubble (left-aligned, markdown body) -->
        <div
          id={"msg-#{@idx}"}
          data-qa="role-bubble"
          class="max-w-[720px] mr-auto p-3 rounded-tl-xl rounded-tr-xl rounded-br-xl rounded-bl-xs bg-slate-100 dark:bg-slate-700 text-slate-900 dark:text-slate-100 border border-slate-300 dark:border-slate-600/50 space-y-2 shadow-xs"
        >
          <div class="flex items-center gap-1.5 text-xs font-bold text-blue-600 dark:text-blue-500">
            <.icon name={@role.icon_name} class="h-3.5 w-3.5 shrink-0" />
            <span>{@role.name}</span>
          </div>
          <div class="select-text prose dark:prose-invert max-w-none text-[13px] leading-relaxed">
            <.markdown content={@text} />
          </div>
        </div>
      <% :activity -> %>
        <!-- 4.8 _ActivityTile (collapsible tool activity) -->
        <% expanded = activity_expanded?(@idx, @expanded_activities) %>
        <% step_count = count_lines(@text) %>
        <div
          id={"activity-tile-#{@idx}"}
          data-qa="activity-tile"
          class="rounded-lg border border-slate-300 dark:border-slate-600/40 bg-slate-50 dark:bg-slate-800 overflow-hidden my-1"
        >
          <button
            type="button"
            phx-click="toggle_activity"
            phx-target={@target}
            phx-value-index={@idx}
            class="w-full flex items-center justify-between px-3 py-2 text-xs font-mono text-slate-500 dark:text-slate-400 hover:bg-slate-100 dark:hover:bg-slate-700 transition-colors cursor-pointer text-left"
          >
            <div class="flex items-center gap-2">
              <.icon name="pi-wrench" class="h-3.5 w-3.5 shrink-0" />
              <span>
                {if step_count == 1,
                  do: "Tool activity (1 step)",
                  else: "Tool activity (#{step_count} steps)"}
              </span>
            </div>
            <.icon
              name={if expanded, do: "pi-caret-up", else: "pi-caret-down"}
              class="h-4 w-4 shrink-0"
            />
          </button>

          <div
            :if={expanded}
            id={"activity-content-#{@idx}"}
            data-qa="activity-content"
            class="p-2.5 bg-black/85 text-cyan-300 font-mono text-[11px] whitespace-pre-wrap select-text border-t border-zinc-800"
          >
            {@text}
          </div>
        </div>
      <% a when a in [:event, :system] -> %>
        <%= if @handoff do %>
          <!-- 4.8 _HandoffTile (event with handoff) -->
          <div
            id={"msg-#{@idx}"}
            data-qa="handoff-tile"
            class="p-2.5 rounded-lg bg-amber-500/10 border border-amber-500/40 dark:bg-amber-400/10 space-y-1.5 my-1.5"
          >
            <div class="flex items-center justify-between flex-wrap gap-2">
              <div class="flex items-center gap-2 font-mono text-xs font-bold text-amber-700 dark:text-amber-300">
                <.icon
                  name={
                    if @handoff.direction == :received,
                      do: "pi-arrow-down-left",
                      else: "pi-arrow-up-right"
                  }
                  class="h-4 w-4 shrink-0"
                />
                <span class="select-text">{@handoff.summary}</span>
              </div>

              <!-- Button to open target role conversation if run exists -->
              <button
                :if={has_run_for_role?(@runs, @handoff.role_id)}
                type="button"
                id={"open-role-conv-#{@idx}"}
                data-qa="open-role-conversation"
                phx-click="select_role"
                phx-target={@target}
                phx-value-role_id={@handoff.role_id}
                class="px-2 py-0.5 rounded text-[11px] font-semibold text-amber-800 dark:text-amber-200 hover:bg-amber-500/20 transition-colors cursor-pointer"
              >
                {"Open #{resolve_role_name(@handoff.role_id, @roles_map)} conversation"}
              </button>
            </div>

            <!-- Optional handoff note -->
            <div
              :if={is_binary(@handoff.note) and @handoff.note != ""}
              class="text-xs font-mono text-slate-600 dark:text-slate-300 whitespace-pre-wrap select-text pt-1 border-t border-amber-500/20"
            >
              {@handoff.note}
            </div>
          </div>
        <% else %>
          <!-- 4.8 _EventTile (event without handoff) -->
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
        is_thinking -> "Message #{role_name} (sends when it is done)..."
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
      class="p-4 bg-white dark:bg-slate-900 border-t border-slate-200 dark:border-slate-700"
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
          class="flex-1 px-3 py-2 text-xs sm:text-sm rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500 disabled:opacity-50 disabled:cursor-not-allowed"
        />

        <button
          type="submit"
          id="chat-send-button"
          data-qa="chat-submit chat-send-button"
          disabled={@is_unavailable or @chat_sending or String.trim(@chat_input) == ""}
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
      class="w-full p-4 bg-zinc-950 text-zinc-300 font-mono text-xs overflow-y-auto max-h-[560px] rounded-b-xl select-text"
    >
      <%= if not @has_lines do %>
        <div id="raw-log-empty-state" class="flex items-center justify-center h-48 text-zinc-500">
          <p>Nothing logged yet.</p>
        </div>
      <% else %>
        <%= for {line, idx} <- Enum.with_index(@lines) do %>
          <% handoff = HandoffLine.parse(line) %>
          <%= if handoff do %>
            <!-- Handoff Line with Button to Open Other Role Log -->
            <div
              id={"raw-log-line-#{idx}"}
              data-qa="raw-log-handoff"
              class="flex items-center justify-between flex-wrap gap-2 py-1 text-amber-300 font-bold"
            >
              <div class="flex items-center gap-2">
                <.icon
                  name={
                    if handoff.direction == :received,
                      do: "pi-arrow-down-left",
                      else: "pi-arrow-up-right"
                  }
                  class="h-3.5 w-3.5 shrink-0"
                />
                <span>{handoff.summary}</span>
              </div>

              <button
                :if={has_run_for_role?(@runs, handoff.role_id)}
                type="button"
                id={"open-role-log-#{idx}"}
                data-qa="open-role-log"
                phx-click="select_role"
                phx-target={@target}
                phx-value-role_id={handoff.role_id}
                class="px-2 py-0.5 rounded text-[11px] border border-amber-400/40 text-amber-200 hover:bg-amber-400/20 transition-colors cursor-pointer"
              >
                {"Open #{resolve_role_name(handoff.role_id, @roles_map)} log"}
              </button>
            </div>
          <% else %>
            <!-- Colored Log Line -->
            <div
              id={"raw-log-line-#{idx}"}
              data-qa="raw-log-line"
              class={["leading-relaxed whitespace-pre-wrap", raw_log_color_class(line)]}
            >
              {line}
            </div>
          <% end %>
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
    index = to_index(index)
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

    case socket.assigns.selected_run do
      %Run{} = run -> {:noreply, send_chat(socket, run, message)}
      nil -> {:noreply, socket}
    end
  end

  # Stopping hands back whatever had not been delivered, and the composer is where
  # it belongs: still the human's to edit, re-send or throw away.
  def handle_event("stop_run", _params, socket) do
    case socket.assigns.selected_run do
      %Run{} = run ->
        {:ok, run, queued} = Pipeline.stop_run(run)

        {:noreply,
         socket
         |> assign(:chat_input, restore_draft(queued, socket.assigns.chat_input))
         |> select(run)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("stop_and_send_message", _params, socket) do
    case socket.assigns.selected_run do
      %Run{} = run ->
        _sent = Pipeline.stop_and_send_message(run)
        {:noreply, select(socket, run)}

      nil ->
        {:noreply, socket}
    end
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
    run = Runs.get_run(run.id) |> elem(1) |> then(&(&1 || run))

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
    |> assign_new(:show_raw_log, fn -> false end)
    |> assign_new(:expanded_activities, fn -> MapSet.new() end)
    |> assign_new(:chat_input, fn -> "" end)
    |> assign_new(:chat_sending, fn -> false end)
    |> assign_new(:run_events, fn -> [] end)
  end

  # The log the component holds; the rendered lines and the parsed transcript are
  # both derived from it, so an appended batch only updates one list.
  defp assign_run_events(socket, run_events) do
    lines = Enum.map(run_events, & &1.line)

    socket
    |> assign(:run_events, run_events)
    |> assign(:log_lines, lines)
    |> assign(:transcript, ChatTranscript.parse(lines))
  end

  defp load_run_events(%Run{} = run), do: Runs.list_run_events(run)
  defp load_run_events(_no_run), do: []

  # The run the human was reading stays selected across a refresh; otherwise the
  # most recent one is what they want to see.
  defp pick_run(runs, %Run{id: id}), do: Enum.find(runs, &(&1.id == id)) || List.last(runs)
  defp pick_run(runs, nil), do: List.last(runs)

  defp sort_runs(runs) do
    Enum.sort_by(runs, &{&1.started_at || &1.inserted_at, &1.inserted_at, &1.id})
  end

  defp selected_role(%Run{role_id: role_id}, roles_map), do: resolve_role(role_id, roles_map)
  defp selected_role(nil, _roles_map), do: nil

  defp to_index(index) when is_integer(index), do: index

  defp to_index(index) do
    case Integer.parse(to_string(index)) do
      {parsed, _rest} -> parsed
      :error -> index
    end
  end

  defp restore_draft(nil, draft), do: draft || ""
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

  defp resolve_role_name(role_id, roles_map) do
    resolve_role(role_id, roles_map).name
  end

  defp format_role_id(role_id) do
    role_id
    |> to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_started_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_started_at(_other), do: nil

  defp format_elapsed_run(%Run{started_at: %DateTime{} = dt, completed_at: %DateTime{} = completed}) do
    secs = max(0, DateTime.diff(completed, dt, :second))
    format_duration(secs)
  end

  defp format_elapsed_run(%Run{started_at: %DateTime{} = dt}) do
    secs = max(0, DateTime.diff(DateTime.utc_now(), dt, :second))
    format_duration(secs)
  end

  defp format_elapsed_run(_other), do: ""

  defp has_usage?(nil), do: false
  defp has_usage?(%TaskUsage{} = usage), do: not TaskUsage.zero?(usage)
  defp has_usage?(_other), do: false

  defp has_run_for_role?(runs, target_role_id) do
    is_list(runs) and
      Enum.any?(runs, fn r ->
        r.role_id == target_role_id or to_string(r.role_id) == to_string(target_role_id)
      end)
  end

  defp count_lines(text) do
    text
    |> to_string()
    |> String.split("\n")
    |> length()
  end

  defp activity_expanded?(idx, %MapSet{} = set) do
    MapSet.member?(set, idx) or MapSet.member?(set, to_string(idx))
  end

  defp activity_expanded?(idx, expanded) do
    is_list(expanded) and (idx in expanded or to_string(idx) in expanded)
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
