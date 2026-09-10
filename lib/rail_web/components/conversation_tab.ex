defmodule RailWeb.Components.ConversationTab do
  @moduledoc """
  Renders the Conversation tab for a task.
  Includes role selector chips, run metadata row, ChatPane with message kinds,
  collapsible tool activity, autoscroll hook, Composer with delivery modes and banners,
  in-flight delivery modal, and the Raw Log view per spec 05 §4.
  """
  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1, markdown: 1]

  alias Rail.Domain.Formatters
  alias Rail.Domain.HandoffLine
  alias Rail.Domain.TaskUsage
  alias Rail.Runs.Schemas.RoleRun

  attr :task, :any, required: true
  attr :ordered_runs, :list, default: []
  attr :selected_run, :any, default: nil
  attr :selected_role_id, :string, default: nil
  attr :selected_role, :any, default: nil
  attr :roles_map, :map, default: %{}
  attr :log_lines, :list, default: []
  attr :transcript, :any, default: nil
  attr :show_raw_log, :boolean, default: false
  attr :expanded_activities, :any, default: []
  attr :chat_input, :string, default: ""
  attr :chat_sending, :boolean, default: false
  attr :active_delivery_modal, :any, default: nil

  def conversation_tab(assigns) do
    runs = assigns.ordered_runs || []

    assigns =
      assigns
      |> assign(:runs, runs)
      |> assign(:has_runs, runs != [])

    ~H"""
    <div id="conversation-tab-root" data-qa="conversation-tab" class="space-y-4">
      <%= if not @has_runs do %>
        <!-- 4.1 Empty State: No role has run this task yet -->
        <div
          id="conversation-empty-state"
          data-qa="conversation_empty_state"
          class="flex items-center justify-center min-h-[300px] text-center p-8 bg-[var(--color-surface)] rounded-xl border border-[var(--color-border)] shadow-xs"
        >
          <p class="text-sm font-medium text-[var(--color-outline)]">
            No role has run this task yet.
          </p>
        </div>
      <% else %>
        <div class="m3-card overflow-hidden divide-y divide-[var(--color-border)]">
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
                  phx-value-role_id={run.role_id}
                  class={[
                    "inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold transition-colors cursor-pointer border",
                    is_selected &&
                      "bg-[var(--color-primary-container)] text-[var(--color-on-primary-container)] border-[var(--color-primary)] shadow-xs",
                    not is_selected &&
                      "bg-[var(--color-surface-container-high)] text-[var(--color-on-surface)] border-[var(--color-outline-variant)] hover:bg-[var(--color-surface-container-highest)]"
                  ]}
                >
                  <.icon name={Formatters.role_icon_for(role.icon_name)} class="h-4 w-4 shrink-0" />
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
              class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-[var(--color-outline)] text-xs font-semibold text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-high)] transition-colors cursor-pointer shrink-0 ml-auto"
            >
              <.icon
                name={if @show_raw_log, do: "chat_bubble_outline", else: "terminal"}
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
            class="flex items-center flex-wrap gap-4 px-6 py-2.5 text-xs text-[var(--color-outline)] bg-[var(--color-surface-container-low)]"
          >
            <!-- 1. selected.status name in lowerCamel -->
            <span id="metadata-run-status" class="font-mono font-semibold">
              {Formatters.format_run_status(@selected_run.status)}
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

            <!-- 3. Attempts count passes -->
            <span :if={(@selected_run.attempts || 0) > 1} id="metadata-run-passes">
              {"#{@selected_run.attempts} passes"}
            </span>

            <!-- 4. Usage describe -->
            <span :if={has_usage?(@selected_run.usage)} id="metadata-run-usage">
              {TaskUsage.describe(@selected_run.usage)}
            </span>

            <!-- 5. Chat usage describe -->
            <span :if={has_usage?(@selected_run.chat_usage)} id="metadata-run-chat-usage">
              {"Chat: #{TaskUsage.describe(@selected_run.chat_usage)}"}
            </span>

            <!-- 6. Selectable conversation id -->
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
              />
            <% else %>
              <!-- 4.7 - 4.12 ChatPane Layout & Composer -->
              <.chat_pane
                task={@task}
                run={@selected_run}
                role={@selected_role}
                transcript={@transcript}
                expanded_activities={@expanded_activities}
                runs={@runs}
                roles_map={@roles_map}
                chat_input={@chat_input}
                chat_sending={@chat_sending}
              />
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- In-Flight Delivery Modal -->
      <.delivery_modal :if={@active_delivery_modal} modal={@active_delivery_modal} />
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

  def chat_pane(assigns) do
    messages =
      if assigns.transcript, do: assigns.transcript.messages || assigns.transcript.turns || [], else: []

    is_pruned =
      if assigns.run,
        do: assigns.run.pruned == true or Map.get(assigns.run, :run_pruned) == true,
        else: false

    assigns =
      assigns
      |> assign(:messages, messages)
      |> assign(:is_pruned, is_pruned)
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
          <!-- Empty State (No messages yet / swept) -->
          <div
            id="chat-empty-state"
            data-qa="chat-empty-state"
            class="flex items-center justify-center h-48 text-center"
          >
            <p class="text-sm font-medium text-[var(--color-outline)]">
              {if @is_pruned,
                do: "This transcript aged out and was swept.",
                else: "No messages yet."}
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
          class="max-w-[600px] ml-auto p-3 rounded-tl-xl rounded-tr-xl rounded-bl-xl rounded-br-xs bg-[var(--color-primary-container)] text-[var(--color-on-primary-container)] space-y-1.5 shadow-xs"
        >
          <div class="flex items-center gap-1.5 text-xs font-bold">
            <.icon name="person" class="h-3.5 w-3.5 shrink-0" />
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
          class="max-w-[720px] mr-auto p-3 rounded-tl-xl rounded-tr-xl rounded-br-xl rounded-bl-xs bg-[var(--color-surface-container-high)] text-[var(--color-on-surface)] border border-[var(--color-outline-variant)]/50 space-y-2 shadow-xs"
        >
          <div class="flex items-center gap-1.5 text-xs font-bold text-[var(--color-primary)]">
            <.icon name={Formatters.role_icon_for(@role.icon_name)} class="h-3.5 w-3.5 shrink-0" />
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
          class="rounded-lg border border-[var(--color-outline-variant)]/40 bg-[var(--color-surface-container-low)] overflow-hidden my-1"
        >
          <button
            type="button"
            phx-click="toggle_activity"
            phx-value-index={@idx}
            class="w-full flex items-center justify-between px-3 py-2 text-xs font-mono text-[var(--color-outline)] hover:bg-[var(--color-surface-container-high)] transition-colors cursor-pointer text-left"
          >
            <div class="flex items-center gap-2">
              <.icon name="build_outlined" class="h-3.5 w-3.5 shrink-0" />
              <span>
                {if step_count == 1,
                  do: "Tool activity (1 step)",
                  else: "Tool activity (#{step_count} steps)"}
              </span>
            </div>
            <.icon
              name={if expanded, do: "expand_less", else: "expand_more"}
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
                  name={if @handoff.direction == :received, do: "call_received", else: "call_made"}
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
                phx-value-role_id={@handoff.role_id}
                class="px-2 py-0.5 rounded text-[11px] font-semibold text-amber-800 dark:text-amber-200 hover:bg-amber-500/20 transition-colors cursor-pointer"
              >
                {"Open #{resolve_role_name(@handoff.role_id, @roles_map)} conversation"}
              </button>
            </div>

            <!-- Optional handoff note -->
            <div
              :if={is_binary(@handoff.note) and @handoff.note != ""}
              class="text-xs font-mono text-[var(--color-on-surface-variant)] whitespace-pre-wrap select-text pt-1 border-t border-amber-500/20"
            >
              {@handoff.note}
            </div>
          </div>
        <% else %>
          <!-- 4.8 _EventTile (event without handoff) -->
          <%= if String.starts_with?(@text, "[axis]") do %>
            <div
              id={"msg-#{@idx}"}
              data-qa="axis-event"
              class="flex items-center gap-2 px-2.5 py-1.5 rounded-md bg-blue-500/10 border border-blue-500/30 text-blue-700 dark:text-blue-300 font-mono text-[11px] my-1"
            >
              <.icon name="info_outline" class="h-3.5 w-3.5 shrink-0" />
              <span class="select-text">{@text}</span>
            </div>
          <% else %>
            <div
              id={"msg-#{@idx}"}
              data-qa="system-event"
              class="text-center font-mono text-[11px] text-[var(--color-outline)] select-text my-0.5"
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

  def composer(assigns) do
    role = assigns.role
    run = assigns.run
    task = assigns.task

    role_id = if is_map(role), do: Map.get(role, :id)
    role_name = if is_map(role), do: Map.get(role, :name, "role"), else: "role"

    is_thinking = task.active_chat_role_id != nil and task.active_chat_role_id == role_id
    is_queued = run != nil and is_binary(run.pending_chat) and run.pending_chat != ""
    is_unavailable = run == nil or not RoleRun.can_chat?(run)

    hint_text =
      cond do
        is_unavailable -> "Chat unavailable"
        is_thinking -> "#{role_name} is responding..."
        is_queued -> "Add to queued message..."
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
      data-qa="composer"
      class="p-4 bg-[var(--color-surface)] border-t border-[var(--color-border)]"
    >
      <!-- Precedence Banners: thinking > queued > unavailable -->
      <%= cond do %>
        <% @is_thinking -> %>
          <div
            id="thinking-banner"
            data-qa="thinking-banner"
            class="flex items-center justify-between gap-2 px-3 py-2 rounded-lg bg-[var(--color-primary-container)]/30 border border-[var(--color-primary)]/20 mb-3"
          >
            <div class="flex items-center gap-2 text-xs font-bold text-[var(--color-primary)]">
              <svg class="animate-spin h-3.5 w-3.5" viewBox="0 0 24 24" fill="none">
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
              <span>{"#{@role_name} is thinking..."}</span>
            </div>

            <button
              type="button"
              id="stop-chat-turn"
              data-qa="stop-chat-turn"
              phx-click="stop_chat_turn"
              class="inline-flex items-center gap-1 px-2.5 py-1 rounded text-xs font-semibold text-[var(--color-error)] hover:bg-[var(--color-error-container)]/30 transition-colors cursor-pointer"
            >
              <.icon name="stop" class="h-3.5 w-3.5 shrink-0" />
              <span>Stop</span>
            </button>
          </div>
        <% @is_queued -> %>
          <div
            id="queued-banner"
            data-qa="queued-banner"
            class="flex items-center justify-between gap-2 px-3 py-2 rounded-lg bg-[var(--color-surface-container-high)] border border-[var(--color-outline-variant)] mb-3"
          >
            <div class="flex items-center gap-2 text-xs text-[var(--color-on-surface)] truncate">
              <.icon name="schedule" class="h-4 w-4 shrink-0 text-[var(--color-outline)]" />
              <span class="truncate">
                {"Queued message: \"#{@run.pending_chat}\" (delivers when pipeline pauses)"}
              </span>
            </div>

            <button
              type="button"
              id="cancel-pending-chat"
              data-qa="cancel-pending-chat"
              phx-click="cancel_pending_chat"
              phx-value-role_id={@role_id}
              class="px-2.5 py-1 rounded text-xs font-semibold text-[var(--color-outline)] hover:text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-highest)] transition-colors cursor-pointer shrink-0"
            >
              Cancel
            </button>
          </div>
        <% @is_unavailable -> %>
          <div
            id="unavailable-banner"
            data-qa="unavailable-banner"
            class="flex items-center gap-2 px-3 py-2 rounded-lg bg-[var(--color-surface-container-highest)] text-xs text-[var(--color-outline)] mb-3"
          >
            <.icon name="info_outline" class="h-4 w-4 shrink-0" />
            <span>{"Cannot chat with #{@role_name} yet: the role has not started a conversation."}</span>
          </div>
        <% true -> %>
      <% end %>

      <!-- Input Row (Enter sends) -->
      <form
        id="chat-composer-form"
        phx-submit="send_chat"
        phx-change="chat_input_change"
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
          disabled={@is_unavailable or @is_thinking or @chat_sending}
          autocomplete="off"
          class="flex-1 px-3 py-2 text-xs sm:text-sm rounded-lg border border-[var(--color-outline)] bg-[var(--color-surface)] text-[var(--color-on-surface)] placeholder-[var(--color-outline)] focus:outline-none focus:ring-1 focus:ring-[var(--color-primary)] disabled:opacity-50 disabled:cursor-not-allowed"
        />

        <button
          type="submit"
          id="chat-send-button"
          data-qa="chat-send-button"
          disabled={
            @is_unavailable or @is_thinking or @chat_sending or String.trim(@chat_input) == ""
          }
          class="inline-flex items-center justify-center h-9 w-9 rounded-lg bg-[var(--color-primary)] text-[var(--color-on-primary)] hover:opacity-90 disabled:opacity-50 disabled:cursor-not-allowed transition-opacity shrink-0 cursor-pointer shadow-xs"
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
            <.icon name="send" class="h-4 w-4 shrink-0" />
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

  def raw_log_view(assigns) do
    is_pruned =
      if assigns.run,
        do: assigns.run.pruned == true or Map.get(assigns.run, :run_pruned) == true,
        else: false

    lines = assigns.log_lines || []

    assigns =
      assigns
      |> assign(:lines, lines)
      |> assign(:is_pruned, is_pruned)
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
          <p>
            {if @is_pruned,
              do: "This transcript aged out and was swept.",
              else: "Nothing logged yet."}
          </p>
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
                  name={if handoff.direction == :received, do: "call_received", else: "call_made"}
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

  # --- Delivery Modal Component ---

  attr :modal, :map, required: true

  def delivery_modal(assigns) do
    ~H"""
    <div
      id="delivery-modal-backdrop"
      data-qa="delivery-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
    >
      <div
        id="delivery-modal-card"
        class="w-full max-w-md p-6 rounded-2xl bg-[var(--color-surface)] border border-[var(--color-border)] shadow-xl space-y-4"
      >
        <h3 class="text-lg font-bold text-[var(--color-on-surface)]">
          A run is in flight
        </h3>

        <p class="text-sm text-[var(--color-on-surface-variant)] leading-relaxed">
          The pipeline is currently executing a run. How would you like to deliver your message to {@modal.role_name}?
        </p>

        <div class="flex flex-col sm:flex-row items-center justify-end gap-2 pt-2">
          <button
            type="button"
            id="delivery-modal-cancel"
            data-qa="delivery-cancel"
            phx-click="cancel_chat_delivery"
            class="w-full sm:w-auto px-4 py-2 rounded-lg text-xs font-semibold text-[var(--color-outline)] hover:text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-high)] transition-colors cursor-pointer"
          >
            Cancel
          </button>

          <button
            type="button"
            id="delivery-modal-when-finished"
            data-qa="delivery-when-finished"
            phx-click="confirm_chat_delivery"
            phx-value-delivery="when_finished"
            class="w-full sm:w-auto px-4 py-2 rounded-lg text-xs font-semibold border border-[var(--color-outline)] text-[var(--color-on-surface)] hover:bg-[var(--color-surface-container-high)] transition-colors cursor-pointer"
          >
            Deliver when pipeline pauses
          </button>

          <button
            type="button"
            id="delivery-modal-stop-and-send"
            data-qa="delivery-stop-and-send"
            phx-click="confirm_chat_delivery"
            phx-value-delivery="stop_and_send"
            class="w-full sm:w-auto px-4 py-2 rounded-lg text-xs font-semibold bg-[var(--color-primary)] text-[var(--color-on-primary)] hover:opacity-90 transition-opacity shadow-xs cursor-pointer"
          >
            Stop run & send now
          </button>
        </div>
      </div>
    </div>
    """
  end

  # --- Private Helpers ---

  defp resolve_role(role_id, roles_map) do
    if is_map(roles_map) and Map.has_key?(roles_map, role_id) do
      role = Map.get(roles_map, role_id)
      %{id: role_id, name: role.name, icon_name: Map.get(role, :icon_name, "terminal")}
    else
      %{id: role_id, name: format_role_id(role_id), icon_name: "terminal"}
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

  defp format_elapsed_run(%RoleRun{started_at: %DateTime{} = dt, completed_at: %DateTime{} = completed}) do
    secs = max(0, DateTime.diff(completed, dt, :second))
    Formatters.format_duration(secs)
  end

  defp format_elapsed_run(%RoleRun{started_at: %DateTime{} = dt}) do
    secs = max(0, DateTime.diff(DateTime.utc_now(), dt, :second))
    Formatters.format_duration(secs)
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

      String.starts_with?(line, ["[axis", "[run", "[init", "[result", "[reattach"]) ->
        "text-green-400"

      true ->
        "text-zinc-300"
    end
  end
end
