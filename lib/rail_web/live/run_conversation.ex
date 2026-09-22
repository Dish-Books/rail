defmodule RailWeb.Live.RunConversation do
  @moduledoc """
  One task's conversation with its agents, and the composer that talks to them.

  Which run is being read is the page's tab; what is typed into the box and
  whether the raw log is showing mean nothing outside this view, so they live
  here. What the page also owns is the subscription: a LiveComponent cannot
  subscribe, so new log lines arrive through `send_update/3`.
  """
  use RailWeb, :live_component

  import Rail.Pipeline.Utils.DrivingLine

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Turn
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Takes the task and its runs; everything else the conversation decides itself.

  `stage_run` is the run the page's tab picked out, and it is what is read here;
  a tab whose role has not run passes `nil`. Rendered without the key at all, the
  most recent run is read.

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
    selected_run = pick_run(runs, Map.fetch(assigns, :stage_run))

    socket =
      socket
      |> assign(assigns)
      |> assign(:runs, runs)
      |> assign(:selected_run, selected_run)
      |> assign_run_events(load_run_events(selected_run))

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :has_runs, assigns.selected_run != nil)

    ~H"""
    <div
      id="conversation-tab-root"
      data-qa="conversation-tab"
      class="flex flex-col flex-1 min-h-0"
    >
      <%= if not @has_runs do %>
        <!-- 4.1 Empty State: the role on the tab has not run this task -->
        <div
          id="conversation-empty-state"
          data-qa="conversation_empty_state"
          class="flex flex-1 items-center justify-center min-h-[300px] text-center p-8"
        >
          <p class="text-sm font-medium text-slate-500 dark:text-slate-400">
            This role has not run on the task yet.
          </p>
        </div>
      <% else %>
        <div class="flex flex-col flex-1 min-h-0">
          <!-- 4.3 Role Row: who is being read, and for how long -->
          <div
            id="role-selector-row"
            data-qa="role-selector-row"
            class="flex items-center gap-x-3 gap-y-2 px-5 py-4 border-b border-slate-200 dark:border-slate-700"
          >
            <% role = selected_role(@selected_run, @roles_map) %>
            <span class={[
              "h-2 w-2 rounded-full shrink-0",
              Run.running?(@selected_run) && "bg-green-500",
              not Run.running?(@selected_run) && "bg-slate-400 dark:bg-slate-500"
            ]} />
            <span
              id={"conversation-role-#{role.id}"}
              data-qa="conversation-role"
              class="text-sm font-semibold text-slate-900 dark:text-slate-100 truncate"
            >
              {role.name}
            </span>

            <!-- Every turn the agent has taken on this run, added up: the run's own
            started_at is reset by each one and says nothing about the rest. -->
            <span
              id={"elapsed-run-#{@selected_run.id}"}
              phx-hook="Elapsed"
              data-started-at={format_started_at(@running_since)}
              data-elapsed-seconds={@settled_seconds}
              data-qa="elapsed-text"
              title="Total time the agent has spent on this run"
              class="ml-auto font-mono text-xs text-slate-500 dark:text-slate-400"
            >
              {format_duration(@elapsed_seconds)}
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
            can_retry={retryable?(@selected_run, @task, @roles_map)}
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
      <% :turn_start -> %>
        <!-- The boundary between one spawn of the agent and the next: when it
        started and what it cost. The log lines carry no time of their own. -->
        <div
          id={"msg-#{@idx}"}
          data-qa="turn-start"
          class="flex items-center gap-3 pt-2 first:pt-0 text-[11px] text-slate-400 dark:text-slate-500"
        >
          <span class="h-px flex-1 bg-slate-200 dark:bg-slate-700" />
          <span class="font-mono shrink-0 flex items-center gap-1.5" data-qa="turn-start-label">
            <span>{@text}</span>
            <%!-- The hook owns this element's whole text, so the separator sits outside it. --%>
            <span :if={@msg.at}>·</span>
            <span
              :if={@msg.at}
              id={"turn-time-#{@idx}"}
              phx-hook="LocalTime"
              data-at={DateTime.to_iso8601(@msg.at)}
              data-qa="turn-time"
            >
              {Calendar.strftime(@msg.at, "%H:%M")}
            </span>
            <span :if={@msg.duration_seconds}>·</span>
            <span :if={@msg.duration_seconds} data-qa="turn-duration">
              {format_duration(@msg.duration_seconds)}
            </span>
          </span>
          <span class="h-px flex-1 bg-slate-200 dark:bg-slate-700" />
        </div>
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
      <% :driving -> %>
        <!-- One thing Rail did to the page, on its own: the instruction it was
        given, or one step it took carrying it out. Separate blocks because they
        are separate events, and a step that was refused or repeated should be as
        countable as one that landed.

        The word for what happened is lifted out of the line and set beside it, so
        a column of these reads as a sequence of actions rather than as forty
        sentences that happen to start differently. -->
        <div
          id={"msg-#{@idx}"}
          data-qa="driving-step"
          data-step={driving_kind(@text)}
          class={[
            "my-1.5 flex items-baseline gap-2.5 rounded-md border px-3 py-2 font-mono text-[11px] select-text",
            driving_kind(@text) == "step" &&
              "relative ml-5 border-slate-200/70 dark:border-slate-700/60 " <>
                "before:absolute before:-left-5 before:-top-1.5 before:-bottom-1.5 before:w-px " <>
                "before:bg-slate-200 dark:before:bg-slate-700 " <>
                "after:absolute after:-left-5 after:top-1/2 after:w-5 after:h-px " <>
                "after:bg-slate-200 dark:after:bg-slate-700",
            driving_kind(@text) == "instruction" &&
              "border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40"
          ]}
        >
          <span
            data-qa="driving-verb"
            class={[
              "shrink-0 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider",
              driving_tone(@text)
            ]}
          >
            {driving_verb(@text)}
          </span>

          <%!-- The line's own wrapping, without the template's indentation. --%><span
            phx-no-format
            class="min-w-0 flex-1 whitespace-pre-wrap wrap-break-word text-slate-600 dark:text-slate-300"
          >{driving_rest(@text)}</span>
        </div>
      <% :command -> %>
        <.command_block
          msg={@msg}
          idx={@idx}
          expanded_activities={@expanded_activities}
          target={@target}
        />
      <% :event -> %>
        <!-- 4.8 _EventTile -->
        <%= cond do %>
          <% String.starts_with?(@text, "[error]") -> %>
            <div
              id={"msg-#{@idx}"}
              data-qa="error-event"
              class="flex items-start gap-2 px-3 py-2 rounded-md bg-red-500/10 border border-red-500/30 text-red-700 dark:text-red-300 text-xs my-1"
            >
              <.icon name="pi-warning-circle" class="h-4 w-4 shrink-0 mt-px" />
              <%!-- Kept on one line: pre-wrap would render the template's own indentation. --%>
              <span
                phx-no-format
                class="select-text font-mono whitespace-pre-wrap wrap-break-word"
              >{String.replace_prefix(@text, "[error] ", "")}</span>
            </div>
          <% String.starts_with?(@text, "[rail]") -> %>
            <div
              id={"msg-#{@idx}"}
              data-qa="rail-event"
              class="flex items-center gap-2 px-2.5 py-1.5 rounded-md bg-blue-500/10 border border-blue-500/30 text-blue-700 dark:text-blue-300 font-mono text-[11px] mt-4 mb-1"
            >
              <.icon name="pi-info" class="h-3.5 w-3.5 shrink-0" />
              <span class="select-text">{@text}</span>
            </div>
          <% true -> %>
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

  # --- Command Block Subcomponent ---

  attr :msg, Turn, required: true
  attr :idx, :integer, required: true
  attr :expanded_activities, MapSet, required: true
  attr :target, :any, required: true

  # Open by default while it runs or once it has failed, which is when its output
  # is what someone came to read; a click flips that either way.
  def command_block(assigns) do
    %Turn{process: %OsProcess{} = process} = assigns.msg
    running? = process.status in [:starting, :running]
    failed? = not running? and process.exit_code != 0

    assigns =
      assigns
      |> assign(:label, command_label(process))
      |> assign(:running?, running?)
      |> assign(:failed?, failed?)
      |> assign(:open?, (running? or failed?) != MapSet.member?(assigns.expanded_activities, assigns.idx))

    ~H"""
    <div
      id={"command-#{@idx}"}
      data-qa="command-block"
      class={[
        "max-w-[720px] mt-4 rounded-lg border bg-white dark:bg-slate-900 overflow-hidden",
        @failed? && "border-red-500/40",
        not @failed? && "border-slate-200 dark:border-slate-700"
      ]}
    >
      <button
        type="button"
        phx-click="toggle_activity"
        phx-target={@target}
        phx-value-index={@idx}
        class="w-full flex items-center gap-2 px-3 py-2 text-xs text-slate-500 dark:text-slate-400 hover:bg-slate-50 dark:hover:bg-slate-800 transition-colors cursor-pointer text-left"
      >
        <.icon name="pi-terminal-window" class="h-3.5 w-3.5 shrink-0" />
        <span class="font-medium text-slate-700 dark:text-slate-300 shrink-0">{@label}</span>
        <span class="font-mono truncate">{@msg.process.command}</span>
        <%!-- A command still running counts up in the browser, as the header does. --%>
        <span
          id={"command-elapsed-#{@msg.process.id}"}
          phx-hook="Elapsed"
          data-started-at={if @running?, do: DateTime.to_iso8601(@msg.process.started_at)}
          data-elapsed-seconds={if @running?, do: 0, else: @msg.duration_seconds}
          data-qa="command-elapsed"
          class="font-mono shrink-0"
        >
          {format_duration(@msg.duration_seconds || 0)}
        </span>
        <span
          data-qa="command-status"
          class={[
            "ml-auto shrink-0 rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider",
            @running? && "bg-blue-500/10 text-blue-700 dark:text-blue-300",
            @failed? && "bg-red-500/10 text-red-700 dark:text-red-300",
            (not @running? and not @failed?) && "bg-green-500/10 text-green-700 dark:text-green-300"
          ]}
        >
          {command_status(@msg.process, @running?)}
        </span>
        <.icon name={if @open?, do: "pi-caret-up", else: "pi-caret-down"} class="h-4 w-4 shrink-0" />
      </button>
      <%!-- Kept on one line: pre-wrap would render the template's own indentation. --%>
      <pre
        :if={@open?}
        id={"command-output-#{@idx}"}
        data-qa="command-output"
        phx-no-format
        class="border-t border-slate-200 dark:border-slate-700 px-3 py-2 max-h-96 overflow-auto font-mono text-[11px] leading-relaxed text-slate-700 dark:text-slate-300 whitespace-pre-wrap wrap-break-word select-text"
      >{@msg.content}</pre>
    </div>
    """
  end

  # --- Composer Component ---

  attr :task, :any, required: true
  attr :run, :any, required: true
  attr :role, :any, required: true
  attr :chat_input, :string, default: ""
  attr :chat_sending, :boolean, default: false
  attr :can_retry, :boolean, default: false
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
        <button
          :if={@can_retry}
          type="button"
          id="retry-run"
          data-qa="retry-run"
          phx-click="retry_run"
          phx-target={@target}
          class="ml-auto inline-flex items-center gap-1 px-2.5 py-1 rounded text-xs font-semibold text-blue-600 dark:text-blue-400 hover:bg-blue-100 dark:hover:bg-blue-900/30 transition-colors cursor-pointer shrink-0"
        >
          <.icon name="pi-arrows-clockwise" class="h-3.5 w-3.5 shrink-0" />
          <span>Retry</span>
        </button>
      </div>

      <!-- Input Row: Enter sends, Shift+Enter writes a newline. -->
      <form
        id="chat-composer-form"
        phx-submit="send_chat"
        phx-change="chat_input_change"
        phx-target={@target}
        class="flex items-end gap-2"
      >
        <input type="hidden" name="role_id" value={@role_id} />
        <%!-- Kept on one line: a textarea renders the template's own indentation. --%>
        <textarea
          id="chat-input"
          name="message"
          data-qa="chat-input"
          rows="1"
          placeholder={@hint_text}
          disabled={@is_unavailable or @chat_sending}
          autocomplete="off"
          phx-hook="ChatComposer"
          phx-debounce="300"
          phx-no-format
          class="flex-1 resize-none px-3 py-2 text-xs sm:text-sm rounded-lg border border-slate-500 dark:border-slate-400 bg-white dark:bg-slate-900 text-slate-900 dark:text-slate-100 placeholder-slate-500 dark:placeholder-slate-400 focus:outline-none focus:ring-1 focus:ring-blue-600 dark:focus:ring-blue-500 disabled:opacity-50 disabled:cursor-not-allowed"
        >{@chat_input}</textarea>

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

  # With no conversation there is nothing a message could resume, so the stage is
  # entered again: the run goes back to running and its role starts on the brief.
  def handle_event("retry_run", _params, socket) do
    %{task: task, selected_run: run, roles_map: roles_map} = socket.assigns

    if retryable?(run, task, roles_map) do
      {:ok, %Run{} = run} = Pipeline.enter_stage(task, roles_map[run.role_id].stage)
      {:noreply, select(socket, run)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("stop_and_send_message", _params, socket) do
    run = socket.assigns.selected_run
    _sent = Pipeline.stop_and_send_message(run)
    {:noreply, select(socket, run)}
  end

  # --- Private Helpers ---

  # Every line carries the same prefix, and forty of those down the left is a
  # column of noise: what varies is what happened.
  # Rail indents the steps it actually took under the instruction it was given,
  # so the shape of the line is already the difference between the two.
  defp driving_kind(text) do
    if String.starts_with?(driving_line(text) || "", " "), do: "step", else: "instruction"
  end

  defp driving_verb(text), do: text |> driving_split() |> elem(0)
  defp driving_rest(text), do: text |> driving_split() |> elem(1)

  # Every line starts with what happened - `do`, `goto`, `check`, `CLICK`,
  # `REFUSED` - and the rest is what it happened to.
  defp driving_split(text) do
    case (driving_line(text) || text) |> String.trim() |> String.split(" ", parts: 2) do
      [verb, rest] -> {verb, rest}
      [verb] -> {verb, ""}
    end
  end

  # A refusal is the one of these a reader should stop at. What Rail asked for
  # and what it managed to do read as themselves.
  defp driving_tone(text) do
    case driving_verb(text) do
      "REFUSED" -> "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"
      "check" -> "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
      "plan" -> "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
      verb -> if verb == String.upcase(verb), do: step_tone(), else: asked_tone()
    end
  end

  defp step_tone, do: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"
  defp asked_tone, do: "bg-blue-100 text-blue-700 dark:bg-blue-950 dark:text-blue-300"

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
  #
  # The log is parsed a turn at a time rather than all at once, because a turn is
  # one process's stream and its own self-contained NDJSON, and because that is
  # the only place the time of anything is known: the lines carry none.
  defp assign_run_events(socket, run_events) do
    socket = load_os_processes(socket, run_events)
    processes = socket.assigns.os_processes
    lines = Enum.map(run_events, & &1.line)

    {turns, _next_number} =
      run_events
      |> group_by_turn()
      |> Enum.flat_map_reduce(1, fn {os_process_id, events}, number ->
        case Map.get(processes, os_process_id) do
          %OsProcess{kind: :agent} = os_process -> {[turn_start(os_process, number) | said(events, socket)], number + 1}
          %OsProcess{} = os_process -> {command_turn(os_process, events, socket), number}
          nil -> {said(events, socket), number}
        end
      end)

    socket
    |> assign(:run_events, run_events)
    |> assign(:log_lines, lines)
    |> assign(:turns, turns)
    |> assign_elapsed(Map.values(processes))
  end

  defp said(events, socket) do
    events |> Enum.map(& &1.line) |> readable_lines(socket.assigns) |> Pipeline.parse_transcript()
  end

  # A command's output is read as it was written. Lines Rail wrote while it ran
  # are not its output, so they follow it as themselves.
  defp command_turn(%OsProcess{} = os_process, events, socket) do
    {output, interjected} = Enum.split_with(events, &(turn_id(&1) == os_process.id))

    turn = %Turn{
      author: :command,
      content: output |> Enum.map_join("\n", & &1.line) |> Tools.plain_text(),
      at: os_process.started_at,
      duration_seconds: OsProcess.duration_seconds(os_process),
      process: os_process
    }

    [turn | said(interjected, socket)]
  end

  # Consecutive events of one process are one turn. Rail writes lines of its own
  # with no process behind them; they belong to the turn they interrupted rather
  # than to one of their own.
  defp group_by_turn(run_events) do
    run_events
    |> Enum.chunk_while(
      nil,
      fn event, current ->
        case {current, turn_id(event)} do
          {nil, id} -> {:cont, {id, [event]}}
          {{id, events}, nil} -> {:cont, {id, [event | events]}}
          {{id, events}, id} -> {:cont, {id, [event | events]}}
          {done, id} -> {:cont, finish_turn(done), {id, [event]}}
        end
      end,
      fn
        nil -> {:cont, []}
        current -> {:cont, finish_turn(current), []}
      end
    )
    |> Enum.reject(&(&1 == []))
  end

  defp finish_turn({id, events}), do: {id, Enum.reverse(events)}

  # Lines broadcast to an open conversation are whatever the writer sent, which
  # is not always a full row, so the turn is read off the event rather than
  # assumed onto it.
  defp turn_id(event), do: Map.get(event, :os_process_id)

  defp turn_start(%OsProcess{} = os_process, number) do
    %Turn{
      author: :turn_start,
      content: "Turn #{number}",
      at: os_process.started_at,
      duration_seconds: OsProcess.duration_seconds(os_process)
    }
  end

  # The processes are the run's turns, and there are only ever a handful, so they
  # are read once and again only when a turn nobody has seen shows up.
  defp load_os_processes(socket, run_events) do
    held = socket.assigns[:os_processes] || %{}
    seen = run_events |> Enum.map(&turn_id/1) |> Enum.reject(&is_nil/1) |> MapSet.new()

    if held != %{} and Enum.all?(seen, &Map.has_key?(held, &1)) and not stale?(held) do
      assign(socket, :os_processes, held)
    else
      assign(socket, :os_processes, read_os_processes(socket.assigns.selected_run))
    end
  end

  # A turn still going has no duration yet, so its row is re-read rather than
  # trusted to still say what it said.
  defp stale?(processes) do
    Enum.any?(Map.values(processes), &(&1.status in [:starting, :running]))
  end

  defp read_os_processes(%Run{id: run_id}) do
    [run_id: run_id] |> Tools.list_os_processes() |> Map.new(&{&1.id, &1})
  end

  defp read_os_processes(_no_run), do: %{}

  # The run's own `started_at` is reset by every turn, so the total comes from the
  # turns themselves. What is already settled is a number; what is still running
  # has to keep counting in the browser, so it goes over as the time it began.
  defp assign_elapsed(socket, processes) do
    {running, settled} = Enum.split_with(processes, &(&1.status in [:starting, :running]))
    settled_seconds = OsProcess.total_duration_seconds(settled)
    running_since = running |> Enum.map(& &1.started_at) |> Enum.min(DateTime, fn -> nil end)

    socket
    |> assign(:settled_seconds, settled_seconds)
    |> assign(:running_since, running_since)
    |> assign(:elapsed_seconds, settled_seconds + OsProcess.total_duration_seconds(running))
  end

  defp readable_lines(lines, %{selected_run: %Run{role_id: role_id}, roles_map: %{} = roles_map}) do
    case roles_map do
      %{^role_id => %{backend: %Backend{} = backend}} -> Tools.parse_stream(backend, lines).logs
      _unknown_backend -> lines
    end
  end

  defp load_run_events(%Run{} = run), do: Pipeline.list_run_events(run)
  defp load_run_events(_no_run), do: []

  # The page's tab says which run is being read, and a role with no run yet reads
  # as nothing. Rendered without one, the most recent run is what to show.
  defp pick_run(runs, {:ok, %Run{id: id}}), do: Enum.find(runs, &(&1.id == id))
  defp pick_run(_runs, {:ok, nil}), do: nil
  defp pick_run(runs, :error), do: List.last(runs)

  defp sort_runs(runs) do
    Enum.sort_by(runs, &{&1.started_at || &1.inserted_at, &1.inserted_at, &1.id})
  end

  defp selected_role(%Run{role_id: role_id}, roles_map), do: resolve_role(role_id, roles_map)

  # Only the stage the task is in can be entered again without moving the task.
  # Product is started from its issue, so entering it again would lose its brief.
  defp retryable?(%Run{role_id: role_id} = run, %{stage: stage}, %{} = roles_map) when stage != :product do
    not Run.running?(run) and not Run.resumable?(run) and match?(%{stage: ^stage}, roles_map[role_id])
  end

  defp retryable?(_run, _task, _roles_map), do: false

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
  defp format_started_at(_not_running), do: nil

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

  defp command_label(%OsProcess{kind: :setup}), do: "Worktree setup"
  defp command_label(%OsProcess{kind: :ci}), do: "CI"

  defp command_status(%OsProcess{}, true), do: "Running"
  defp command_status(%OsProcess{exit_code: 0}, false), do: "Passed"
  defp command_status(%OsProcess{exit_code: 124}, false), do: "Timed out"
  defp command_status(%OsProcess{exit_code: code}, false) when is_integer(code) and code > 0, do: "Failed · exit #{code}"
  defp command_status(%OsProcess{}, false), do: "Stopped"
end
