defmodule RailWeb.Live.PlanStage do
  @moduledoc """
  The Plan step: the ticket, the design options and the plan, a list of three with the selected one
  beside it in today's ticket, design and plan views, and the one Approve in the header.

  Everything here is read off scratch and the runs whenever the page reloads it, so a save shows
  the moment it lands. The item open by default is whatever waits on the human; a click keeps theirs.

  Once a design is picked the reader can comment on its elements while Plan can take a message. The mode and the
  open comment box are this tab's alone; the comments are rows, and the conversation sends them.
  """
  use RailWeb, :live_component

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  # Another of the reader's tabs saved, removed or sent plan comments. Only the markers moved.
  @impl true
  def update(%{reload_comments: true}, socket) do
    {:ok, assign_comments(socket)}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:commenting, fn -> false end)
      |> assign_new(:draft, fn -> nil end)
      |> assign_new(:chosen_item, fn -> nil end)
      |> assign_new(:selected_key, fn -> nil end)
      |> assign_new(:diagram_views, fn -> %{change: :diagram, call_flow: :diagram} end)
      |> load()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="plan-stage" data-qa="plan-stage" class="contents">
      <.task_layout
        task={@task}
        run={@run}
        stage_run={@stage_run}
        line={@line}
        title={@task.issue.title}
        flush
      >
        <:tabs>{render_slot(@tabs)}</:tabs>

        <:actions>
          {render_slot(@actions)}

          <span
            :if={@approved}
            id="plan-approved"
            data-qa="plan_approved"
            class="inline-flex items-center gap-1.5 text-xs font-semibold text-emerald-600 dark:text-emerald-400"
          >
            <.icon name="pi-check-circle" class="size-4" /> Plan approved
          </span>

          <button
            :if={@show_approve}
            type="button"
            id="approve-plan"
            data-qa="approve_plan"
            phx-click="approve"
            phx-target={@myself}
            phx-disable-with="Approving…"
            class="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg text-sm font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs disabled:opacity-60 disabled:cursor-not-allowed"
          >
            <.icon name="pi-check" class="size-4" /> Approve
          </button>
        </:actions>

        <:alerts :if={@error}>
          <p id="plan-error" data-qa="plan_error" class="text-xs text-red-600 dark:text-red-500">
            {@error}
          </p>
        </:alerts>

        <div class="@container h-full">
          <div class="h-full flex flex-col @5xl:flex-row">
            <nav
              id="plan-items"
              aria-label="Plan outputs"
              class="shrink-0 flex @5xl:flex-col gap-2 @5xl:gap-1 p-2 @5xl:w-[280px] border-b @5xl:border-b-0 @5xl:border-r border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/30"
            >
              <button
                :for={item <- @items}
                type="button"
                id={"plan-item-#{item.id}"}
                data-qa="plan_item"
                aria-current={to_string(item.id == @selected_item)}
                phx-click="select_item"
                phx-value-item={item.id}
                phx-target={@myself}
                class={[
                  "flex-1 @5xl:flex-none @5xl:w-full min-w-0 flex gap-2.5 px-3 py-2.5 rounded-lg text-left cursor-pointer",
                  item.id == @selected_item &&
                    "bg-blue-50 dark:bg-blue-950/40 ring-1 ring-blue-200 dark:ring-blue-800",
                  item.id != @selected_item && "hover:bg-slate-100 dark:hover:bg-slate-800/60"
                ]}
              >
                <.icon name={item.icon} class="size-[17px] mt-0.5 text-slate-500 dark:text-slate-300" />
                <span class="min-w-0 flex-1">
                  <span class={[
                    "block text-[13.5px] font-semibold",
                    item.tone == :skipped && "text-slate-500 dark:text-slate-400",
                    item.tone != :skipped && "text-slate-900 dark:text-slate-100"
                  ]}>
                    {item.label}
                  </span>
                  <span
                    id={"plan-item-#{item.id}-status"}
                    class={["block text-[11.5px] truncate", status_class(item.tone)]}
                  >
                    {item.line}<span :if={item.line && item.saved_at}> · </span><span :if={
                      item.saved_at
                    }>saved
                    <.local_time
                      id={"plan-item-#{item.id}-saved"}
                      at={item.saved_at}
                    /></span>
                  </span>
                </span>
                <.item_mark tone={item.tone} />
              </button>
            </nav>

            <div
              id="plan-pane"
              class="flex-1 min-w-0 min-h-0 overflow-y-auto px-6 @5xl:px-8 py-5 @5xl:py-6"
            >
              <.ticket_pane
                :if={@selected_item == "ticket"}
                ticket={@ticket}
                running={@running}
                pick_up={@pick_up}
              />

              <.design_pane
                :if={@selected_item == "design"}
                task={@task}
                design={@design}
                option={@option}
                plan={@plan}
                running={@running}
                pick_up={@pick_up}
                can_pick={@can_pick}
                comment_reason={@comment_reason}
                commenting={@commenting}
                draft={@draft}
                markers={@markers}
                user_id={@current_scope.user.id}
                target={@myself}
              />

              <.plan_pane
                :if={@selected_item == "plan"}
                plan={@plan}
                sheet={@sheet}
                banner={@banner}
                approved={@approved}
                running={@running}
                pending_text={@pending_text}
                diagram_views={@diagram_views}
                target={@myself}
              />
            </div>
          </div>
        </div>

        <:sidebar>{render_slot(@sidebar)}</:sidebar>
      </.task_layout>
    </div>
    """
  end

  @impl true
  def handle_event("select_item", %{"item" => item}, socket) when item in ["ticket", "design", "plan"] do
    socket =
      socket
      |> assign(:chosen_item, item)
      |> assign(:selected_item, item)

    {:noreply, socket}
  end

  def handle_event("select_option", %{"key" => key}, socket) do
    socket =
      socket
      |> assign(:selected_key, key)
      |> assign(:option, shown_option(socket.assigns.design, key))

    {:noreply, socket}
  end

  def handle_event("pick", %{"key" => key}, socket) do
    socket.assigns.current_scope |> Pipeline.pick_design_option(socket.assigns.run, key) |> respond(socket)
  end

  def handle_event("approve", _params, socket) do
    socket.assigns.current_scope |> Pipeline.approve_plan(socket.assigns.run) |> respond(socket)
  end

  def handle_event("toggle_commenting", _params, socket) do
    socket =
      if socket.assigns.comment_reason == nil and not socket.assigns.commenting,
        do: assign(socket, :commenting, true),
        else: socket |> assign(:commenting, false) |> assign(:draft, nil)

    {:noreply, socket}
  end

  def handle_event("stop_commenting", _params, socket) do
    socket = socket |> assign(:commenting, false) |> assign(:draft, nil)

    {:noreply, socket}
  end

  # What a reload kept, taken only as a fresh toggle and click would be: on the pick, while Plan can take a message.
  def handle_event("restore_commenting", params, socket) do
    %{comment_reason: reason, design: design} = socket.assigns
    kept = reason == nil && draft(params["draft"])

    socket =
      cond do
        reason != nil ->
          socket

        match?(%{option_key: key} when key == design.picked, kept) ->
          socket |> assign(:commenting, true) |> assign(:draft, kept)

        kept == nil and params["draft"] == nil and params["commenting"] == true ->
          assign(socket, :commenting, true)

        true ->
          socket
      end

    {:noreply, socket}
  end

  # The element comes from the page in the frame, so only its expected shape is taken; the changeset checks the rest.
  def handle_event("select_element", params, socket) do
    %{commenting: commenting, comment_reason: reason, design: design} = socket.assigns

    socket =
      case commenting and reason == nil and draft(Map.put(params, "option_key", design.picked)) do
        %{} = draft -> assign(socket, :draft, draft)
        _off_or_malformed -> socket
      end

    {:noreply, socket}
  end

  def handle_event("change_plan_comment", %{"body" => body}, %{assigns: %{draft: %{} = draft}} = socket) do
    {:noreply, assign(socket, :draft, %{draft | body: body})}
  end

  def handle_event("change_plan_comment", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_plan_comment", _params, socket) do
    {:noreply, assign(socket, :draft, nil)}
  end

  # A blank comment is refused and the box stays open on what was typed.
  def handle_event("save_plan_comment", %{"body" => body}, %{assigns: %{draft: %{} = draft}} = socket) do
    attrs = %{
      target: :design,
      body: body,
      option_key: draft.option_key,
      selector: draft.selector,
      element_text: draft.text,
      element_tag: draft.tag,
      capture: %{html: draft.html, width: draft.width, height: draft.height}
    }

    case Pipeline.create_plan_comment(socket.assigns.current_scope, socket.assigns.run, attrs) do
      {:ok, _comment} ->
        socket = socket |> assign(:draft, nil) |> assign(:error, nil) |> assign_comments()
        {:noreply, socket}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, :draft, %{draft | body: body})}

      {:error, reason} ->
        socket |> assign(:draft, nil) |> then(&respond({:error, reason}, &1))
    end
  end

  def handle_event("save_plan_comment", _params, socket), do: {:noreply, socket}

  def handle_event("diagram_view", %{"view" => view}, socket) do
    [diagram, shown] = String.split(view, ":")
    diagram = if diagram == "call_flow", do: :call_flow, else: :change
    shown = if shown == "source", do: :source, else: :diagram

    {:noreply, update(socket, :diagram_views, &Map.put(&1, diagram, shown))}
  end

  # --- Panes ---

  attr :ticket, :any, required: true
  attr :running, :boolean, required: true
  attr :pick_up, :string, required: true

  defp ticket_pane(assigns) do
    ~H"""
    <.pending
      :if={@ticket == nil}
      id="plan-ticket-pending"
      icon="pi-file-text"
      running={@running}
      title={if @running, do: "Writing the ticket", else: "No ticket yet"}
      text={
        if @running,
          do:
            "Product is reading the issue and the code it touches. The ticket appears here as soon as it is saved.",
          else: "Plan stopped before saving a ticket. " <> @pick_up
      }
    />

    <div :if={@ticket != nil} id="plan-ticket" data-qa="plan_ticket" class="max-w-3xl select-text">
      <h2
        id="plan-ticket-title"
        class="mb-4 text-xl font-bold text-slate-900 dark:text-slate-100 wrap-break-word"
      >
        {@ticket.title}
      </h2>
      <.markdown content={@ticket.description} class="text-[15px] leading-relaxed" />
    </div>
    """
  end

  attr :task, Task, required: true
  attr :design, :any, required: true
  attr :option, :any, required: true
  attr :plan, :any, required: true
  attr :running, :boolean, required: true
  attr :pick_up, :string, required: true
  attr :can_pick, :boolean, required: true
  attr :comment_reason, :string, default: nil, doc: "why commenting cannot be turned on, or nil when it can"
  attr :commenting, :boolean, required: true
  attr :draft, :map, default: nil, doc: "the element the comment box is open on, with what is typed so far"
  attr :markers, :list, required: true
  attr :user_id, :string, required: true
  attr :target, :any, required: true

  defp design_pane(assigns) do
    assigns =
      assigns
      |> assign(:picked, assigns.design && assigns.design.picked)
      |> assign(:slots, slots(assigns.design, assigns.running))
      |> assign(:full, match?(%{options: [_one, _two, _three]}, assigns.design))

    ~H"""
    <div
      :if={@option == nil and @plan != nil and not @running}
      id="plan-design-none"
      data-qa="plan_design_none"
      class="flex flex-col items-center text-center max-w-md mx-auto py-14"
    >
      <div class="flex items-center justify-center size-14 rounded-2xl bg-slate-100 dark:bg-slate-800 text-slate-400 ring-1 ring-slate-200 dark:ring-slate-700">
        <.icon name="pi-minus-circle" class="size-7" />
      </div>
      <h2 class="mt-5 text-base font-semibold text-slate-900 dark:text-slate-100">
        No screen in this change
      </h2>
      <p class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">
        Nothing anyone sees changes, so there are no design options. Approve needs only the ticket and the plan.
      </p>
    </div>

    <.pending
      :if={@option == nil and (@plan == nil or @running)}
      id="plan-design-pending"
      icon="pi-palette"
      running={@running}
      title={if @running, do: "Designing", else: "No design options yet"}
      text={
        if @running,
          do:
            "When the change has a screen, the Designer mocks up three directions. Each appears here as soon as it is saved.",
          else: "Plan stopped before saving any design options. " <> @pick_up
      }
    />

    <div
      :if={@option != nil}
      id="design-options"
      data-qa="design_options"
      class={[
        "@container flex flex-col gap-6",
        @picked == nil &&
          "rounded-2xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900/60 p-4 sm:p-6"
      ]}
    >
      <div
        :if={@picked == nil}
        role="tablist"
        aria-label="Design options"
        class="grid grid-cols-3 gap-2 @2xl:gap-3"
      >
        <button
          :for={option <- @design.options}
          type="button"
          role="tab"
          id={"design-tab-#{option.key}"}
          data-qa="design_tab"
          aria-selected={to_string(option.key == @option.key)}
          phx-click="select_option"
          phx-value-key={option.key}
          phx-target={@target}
          class={[
            "flex items-center gap-3 min-w-0 p-2 @2xl:p-3 rounded-xl border text-left transition-colors cursor-pointer",
            option.key == @option.key &&
              "border-slate-400 bg-slate-100 dark:border-slate-500 dark:bg-slate-800",
            option.key != @option.key &&
              "border-slate-200 dark:border-slate-700 hover:bg-slate-50 dark:hover:bg-slate-800/50"
          ]}
        >
          <img
            :if={option.screenshot_version}
            src={
              ~p"/tasks/#{@task.id}/design/#{option.key}/screenshot?v=#{option.screenshot_version}"
            }
            alt=""
            class="hidden @2xl:block w-20 shrink-0 aspect-video rounded-md object-cover object-top border border-slate-200 dark:border-slate-700 bg-white"
          />
          <span
            :if={option.screenshot_version == nil}
            class="hidden @2xl:block w-20 shrink-0 aspect-video rounded-md border border-dashed border-slate-300 dark:border-slate-700"
          />
          <span class="min-w-0">
            <span class="block text-sm font-semibold text-slate-900 dark:text-slate-100 truncate">
              {option.title}
            </span>
            <span class="block font-mono text-xs text-slate-500 dark:text-slate-400 truncate">
              {option.key}
            </span>
          </span>
        </button>

        <div
          :for={slot <- @slots}
          id={"design-tab-#{slot.state}-#{slot.number}"}
          data-qa={"design_tab_#{slot.state}"}
          class={[
            "flex items-center gap-3 min-w-0 p-2 @2xl:p-3 rounded-xl border border-dashed text-slate-500",
            slot.state == :building && "border-slate-300 dark:border-slate-700",
            slot.state == :missing && "border-red-300 dark:border-red-900"
          ]}
        >
          <span class={[
            "hidden @2xl:block w-20 shrink-0 aspect-video rounded-md border border-dashed border-slate-300 dark:border-slate-700 bg-slate-50 dark:bg-slate-900",
            slot.state == :building && "motion-safe:animate-pulse"
          ]} />
          <span class="min-w-0">
            <span class="flex items-center gap-1.5 text-sm font-semibold text-slate-500 dark:text-slate-400">
              <span
                :if={slot.state == :building}
                class="size-3 shrink-0 rounded-full border-2 border-slate-300 dark:border-slate-600 border-t-blue-500 motion-safe:animate-spin"
              />
              <.icon
                :if={slot.state == :missing}
                name="pi-warning-circle"
                class="size-4 text-red-500"
              /> Option {slot.number}
            </span>
            <span class={[
              "block text-xs truncate",
              slot.state == :building && "text-slate-500",
              slot.state == :missing && "text-red-600 dark:text-red-300"
            ]}>
              {if slot.state == :building, do: "Being built", else: "Not saved"}
            </span>
          </span>
        </div>
      </div>

      <div id={"design-option-#{@option.key}"} data-qa="design_option" class="flex flex-col gap-6">
        <div class="flex flex-col gap-2.5">
          <.design_comment_control
            commenting={@commenting}
            disabled_reason={@comment_reason}
            target={@target}
          />

          <div
            id={"design-frame-#{@option.key}"}
            phx-hook="DesignFrame"
            data-comments={to_string(@picked != nil)}
            data-commenting={to_string(@commenting)}
            data-selected={@draft && @draft.selector}
            data-draft={@draft && Jason.encode!(Map.delete(@draft, :body))}
            data-draft-body={@draft && @draft.body}
            data-markers={Jason.encode!(@markers)}
            data-version={@option.html_version}
            data-task-id={@task.id}
            data-user-id={@user_id}
            data-conversation="#conversation-tab-root"
            class={[
              "relative w-full aspect-video overflow-hidden rounded-xl border border-slate-200 dark:border-slate-700 bg-white",
              @commenting &&
                "ring-2 ring-blue-500 ring-offset-2 ring-offset-white dark:ring-offset-slate-900 cursor-crosshair"
            ]}
          >
            <iframe
              :if={@option.html != nil}
              id={"design-page-#{@option.key}-#{@option.html_version}"}
              title={@option.title}
              sandbox="allow-scripts"
              src={frame_src(@task, @option, @picked)}
              class="absolute top-0 left-0 w-full h-full border-0"
            />
            <p
              :if={@option.html == nil}
              class="absolute inset-0 flex items-center justify-center text-xs text-slate-400"
            >
              This option has no page yet.
            </p>

            <.comment_box
              :if={@draft}
              id={"plan-comment-form-#{draft_key(@draft)}"}
              body_id={"plan-comment-body-#{draft_key(@draft)}"}
              qa="plan_comment"
              label={@draft.tag}
              body={@draft.body}
              submit="save_plan_comment"
              change="change_plan_comment"
              cancel="cancel_plan_comment"
              target={@target}
              class="absolute z-10 shadow-2xl"
              style={box_style(@draft)}
            >
              <:heading>
                <div class="flex items-center gap-1.5 px-1 pb-1.5 min-w-0 text-[11px] text-slate-500 dark:text-slate-400">
                  <span class="shrink-0 font-semibold text-slate-700 dark:text-slate-200">
                    {@draft.tag}
                  </span>
                  <span :if={@draft.text != ""} class="truncate">"{@draft.text}"</span>
                </div>
              </:heading>
            </.comment_box>
          </div>
        </div>

        <div>
          <p
            :if={@picked != nil}
            class="mb-2 inline-flex items-center gap-1.5 text-xs font-semibold text-emerald-600 dark:text-emerald-400"
          >
            <.icon name="pi-check-circle" class="size-4" /> Picked
          </p>
          <h2
            id="design-option-title"
            class="text-2xl font-bold tracking-tight text-slate-900 dark:text-slate-100 wrap-break-word"
          >
            {@option.title}
          </h2>
          <p
            :if={@option.summary != ""}
            class="mt-2 text-sm leading-relaxed text-slate-600 dark:text-slate-300 select-text"
          >
            {@option.summary}
          </p>
        </div>

        <div class="flex items-center gap-3">
          <button
            :if={@picked == nil and @can_pick and (@full or @running)}
            type="button"
            id={"pick-design-#{@option.key}"}
            data-qa="pick_design"
            phx-click="pick"
            phx-value-key={@option.key}
            phx-target={@target}
            disabled={@running}
            title={if @running, do: "Plan is working. Pick once its turn ends."}
            class="flex-1 px-4 py-2.5 rounded-lg text-sm font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs disabled:opacity-50 disabled:cursor-not-allowed"
          >
            Use this design
          </button>

          <a
            :if={@option.html != nil}
            id={"open-design-#{@option.key}"}
            href={~p"/tasks/#{@task.id}/design/#{@option.key}?v=#{@option.html_version}"}
            target="_blank"
            rel="noopener"
            class="inline-flex items-center gap-1.5 px-4 py-2.5 rounded-lg text-sm font-semibold border border-slate-300 dark:border-slate-600 text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800"
          >
            Open <.icon name="pi-arrow-up-right" class="size-4" />
          </a>

          <span
            :if={@picked == nil and @can_pick and not @full and not @running}
            id="pick-in-conversation"
            class="text-[13px] text-slate-500 dark:text-slate-400"
          >
            Pick in the conversation.
          </span>
        </div>

        <.tradeoffs
          :if={@option.good_at != []}
          id="design-good-at"
          label="Good at"
          items={@option.good_at}
          sign="+"
          sign_class="text-emerald-600 dark:text-emerald-400"
        />

        <.tradeoffs
          :if={@option.costs != []}
          id="design-costs"
          label="Costs"
          items={@option.costs}
          sign="−"
          sign_class="text-rose-600 dark:text-rose-400"
        />

        <p
          :if={@option.assumptions != ""}
          id="design-assumptions"
          class="rounded-lg border border-slate-200 dark:border-slate-700 border-l-2 border-l-amber-400 dark:border-l-amber-400 bg-slate-50 dark:bg-slate-800/40 px-4 py-3 text-sm leading-relaxed text-slate-600 dark:text-slate-300 select-text wrap-break-word"
        >
          {@option.assumptions}
        </p>
      </div>
    </div>
    """
  end

  attr :plan, :any, required: true
  attr :sheet, :any, required: true
  attr :banner, :any, required: true
  attr :approved, :boolean, required: true
  attr :running, :boolean, required: true
  attr :pending_text, :string, required: true
  attr :diagram_views, :map, required: true
  attr :target, :any, required: true

  defp plan_pane(assigns) do
    ~H"""
    <.pending
      :if={@plan == nil}
      id="plan-plan-pending"
      icon={if @running, do: "pi-compass-tool", else: "pi-list-checks"}
      running={@running}
      title={if @running, do: "Planning the implementation", else: "No plan yet"}
      text={@pending_text}
    />

    <div
      :if={@banner}
      id="plan-revising"
      data-qa="plan_revising"
      class="mb-5 flex items-center gap-2.5 rounded-lg border border-blue-200 dark:border-blue-900 bg-blue-50 dark:bg-blue-950/40 px-4 py-2.5 text-[13px] text-blue-800 dark:text-blue-200"
    >
      <span
        :if={@running}
        class="size-3 shrink-0 rounded-full border-2 border-slate-300 dark:border-slate-600 border-t-blue-500 motion-safe:animate-spin"
      />
      <span class="min-w-0 wrap-break-word">{@banner}</span>
    </div>

    <div
      :if={@plan != nil}
      id="plan-plan"
      data-qa="plan_plan"
      class={["select-text", @sheet == nil && "max-w-3xl"]}
    >
      <.plan_sheet
        :if={@sheet}
        sheet={@sheet}
        diagram_views={@diagram_views}
        event="diagram_view"
        target={@target}
      />
      <.markdown :if={@sheet == nil} content={@plan.content} class="text-[15px] leading-relaxed" />
      <p :if={@approved} class="mt-6 text-[13px] text-slate-500 dark:text-slate-400">
        Engineer, Code Reviewer, QA and Demo Presenter work from this plan exactly as approved.
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :running, :boolean, required: true
  attr :title, :string, required: true
  attr :text, :string, required: true

  # Nothing to read yet. While Plan works this says what is coming; once it has stopped, the chat is where it resumes.
  defp pending(assigns) do
    ~H"""
    <div id={@id} data-qa={@id} class="flex flex-col items-center text-center max-w-md mx-auto py-14">
      <div class="relative flex items-center justify-center size-14 rounded-2xl bg-blue-50 dark:bg-slate-800 text-blue-600 dark:text-slate-400 ring-1 ring-blue-100 dark:ring-slate-700">
        <span
          :if={@running}
          class="absolute inset-0 rounded-2xl ring-2 ring-blue-400/40 motion-safe:animate-ping"
        />
        <.icon name={@icon} class="size-7" />
      </div>
      <h2 class="mt-5 text-base font-semibold text-slate-900 dark:text-slate-100">{@title}</h2>
      <p class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">{@text}</p>
    </div>
    """
  end

  attr :tone, :atom, required: true

  defp item_mark(%{tone: :working} = assigns) do
    ~H"""
    <span class="mt-0.5">
      <span class="block size-3 shrink-0 rounded-full border-2 border-slate-300 dark:border-slate-600 border-t-blue-500 motion-safe:animate-spin" />
    </span>
    """
  end

  defp item_mark(assigns) do
    assigns = assign(assigns, :mark, mark(assigns.tone))

    ~H"""
    <.icon name={@mark.icon} class={["size-[15px] mt-0.5", @mark.class]} />
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :items, :list, required: true
  attr :sign, :string, required: true
  attr :sign_class, :string, required: true

  defp tradeoffs(assigns) do
    ~H"""
    <div id={@id}>
      <h3 class="text-xs font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
        {@label}
      </h3>
      <ul class="mt-2 space-y-2">
        <li
          :for={item <- @items}
          class="flex gap-3 text-sm leading-relaxed text-slate-700 dark:text-slate-200 select-text wrap-break-word"
        >
          <span class={["shrink-0 font-semibold", @sign_class]} aria-hidden="true">{@sign}</span>
          <span class="min-w-0">{item}</span>
        </li>
      </ul>
    </div>
    """
  end

  # --- What the page reads ---

  defp load(socket) do
    %{task: task, run: run} = socket.assigns
    ticket = Pipeline.read_ticket(task)
    design = Pipeline.read_design(task)
    {plan, approved} = plan(task)
    running = Run.running?(run)
    picked = design && Enum.find(design.options, &(&1.key == design.picked))
    selected_key = selected_key(design, socket.assigns.selected_key)
    items = items(ticket, design, picked, plan, running)

    socket
    |> assign(:ticket, ticket)
    |> assign(:design, design)
    |> assign(:plan, plan)
    |> assign(:sheet, plan && build_plan_sheet(plan.content))
    |> assign(:approved, approved)
    |> assign(:running, running)
    |> assign(:can_pick, task.stage == :plan and Run.can_chat?(run))
    |> assign(:selected_key, selected_key)
    |> assign(:option, shown_option(design, selected_key))
    |> assign(:items, items)
    |> assign(:selected_item, socket.assigns.chosen_item || default_item(items, ticket, plan))
    |> assign(:banner, banner(plan, picked, running))
    |> assign(:pick_up, pick_up(run))
    |> assign(:pending_text, pending_text(running, pick_up(run)))
    |> assign(:show_approve, approvable?(socket.assigns, ticket, design, plan))
    |> assign(:comment_reason, comment_reason(design, run))
    |> stop_commenting_unless_allowed()
    |> assign_comments()
  end

  defp assign_comments(socket) do
    %{current_scope: scope, task: task, design: design} = socket.assigns
    comments = Pipeline.list_plan_comments(scope, task)
    picked = design && design.picked

    markers =
      for {comment, number} <- Enum.with_index(comments, 1),
          comment.target == :design and comment.option_key == picked,
          do: %{id: comment.id, number: number, selector: comment.selector}

    socket
    |> assign(:comments, comments)
    |> assign(:markers, markers)
  end

  # Before a pick there is nothing to comment on, and the pick comes first.
  defp comment_reason(%{picked: picked}, %Run{} = run) when is_binary(picked) do
    if Run.can_chat?(run), do: nil, else: "Cannot chat with #{run.role.name} yet"
  end

  defp comment_reason(_no_pick, _run), do: "Pick a design to comment on it."

  defp stop_commenting_unless_allowed(%{assigns: %{comment_reason: nil}} = socket), do: socket
  defp stop_commenting_unless_allowed(socket), do: socket |> assign(:commenting, false) |> assign(:draft, nil)

  defp frame_src(task, option, nil), do: ~p"/tasks/#{task.id}/design/#{option.key}?v=#{option.html_version}"

  defp frame_src(task, option, _picked),
    do: ~p"/tasks/#{task.id}/design/#{option.key}?v=#{option.html_version}&comments=1"

  defp draft(
         %{
           "option_key" => key,
           "selector" => selector,
           "text" => text,
           "tag" => tag,
           "html" => html,
           "width" => width,
           "height" => height,
           "x" => x,
           "y" => y
         } = params
       )
       when is_binary(key) and is_binary(selector) and is_binary(text) and is_binary(tag) and is_binary(html) and
              is_integer(width) and is_integer(height) and is_integer(x) and is_integer(y) do
    body = if is_binary(params["body"]), do: params["body"]

    %{
      option_key: key,
      selector: selector,
      text: text,
      tag: tag,
      html: html,
      width: width,
      height: height,
      x: x,
      y: y,
      body: body
    }
  end

  defp draft(_malformed), do: nil

  # Named for its element, so a box on another element mounts afresh and takes the focus.
  defp draft_key(draft), do: :erlang.phash2({draft.selector, draft.x, draft.y})

  # Under the element, or above it when it sits low in the frame, in the page's own 1920x1080 coordinates.
  defp box_style(draft) do
    left = "left: clamp(8px, #{percent(draft.x, 1920)}%, calc(100% - 448px)); width: min(440px, calc(100% - 16px));"

    if draft.y + draft.height > 1080 * 0.6,
      do: "#{left} bottom: calc(#{percent(1080 - draft.y, 1080)}% + 10px);",
      else: "#{left} top: calc(#{percent(draft.y + draft.height, 1080)}% + 10px);"
  end

  defp percent(value, whole), do: Float.round(value / whole * 100, 3)

  # Once the task has left Plan the page shows what the later stages were given.
  defp plan(%Task{stage: :plan} = task), do: {Pipeline.read_plan(task), false}

  defp plan(%Task{} = task) do
    case Pipeline.get_implementation_plan(task) do
      {:ok, %ImplementationPlan{content: content, captured_at: captured_at}} ->
        scratch = Pipeline.read_plan(task)

        {%{content: content, saved_at: (scratch && scratch.saved_at) || captured_at, design: scratch && scratch.design},
         true}

      {:error, :not_found} ->
        {Pipeline.read_plan(task), false}
    end
  end

  defp approvable?(%{approvable: approvable}, ticket, design, plan) do
    approvable and ticket != nil and plan != nil and
      case design do
        %{options: [_first | _rest], picked: picked} ->
          is_binary(picked) and plan.design != nil and plan.design.key == picked

        _no_options ->
          true
      end
  end

  defp items(ticket, design, picked, plan, running) do
    options = if design, do: design.options, else: []
    plan_sheet = plan && build_plan_sheet(plan.content)

    [
      ticket_item(ticket, running),
      design_item(options, picked, plan, running),
      plan_item(plan, plan_sheet, picked, running)
    ]
  end

  defp ticket_item(nil, running) do
    %{
      id: "ticket",
      label: "Ticket",
      icon: "pi-file-text",
      line: if(running, do: "Being written", else: "Not saved yet"),
      saved_at: nil,
      tone: if(running, do: :working, else: :empty)
    }
  end

  defp ticket_item(ticket, _running) do
    count = criteria(ticket.description)
    line = if count > 0, do: "#{count} #{if count == 1, do: "criterion", else: "criteria"}"

    %{id: "ticket", label: "Ticket", icon: "pi-file-text", line: line, saved_at: ticket.saved_at, tone: :done}
  end

  defp design_item(options, picked, plan, running) do
    count = length(options)

    {line, tone} =
      cond do
        picked != nil -> {"Picked: #{picked.title}", :done}
        options == [] and plan != nil and not running -> {"No screen in this change", :skipped}
        options == [] -> {"Not saved yet", if(running, do: :working, else: :empty)}
        running -> {"#{count} of 3 saved", :working}
        count == 3 -> {"Pick one of 3", :pick}
        true -> {"#{count} of 3 saved: needs 3", :failed}
      end

    %{id: "design", label: "Design", icon: "pi-palette", line: line, saved_at: nil, tone: tone}
  end

  defp plan_item(nil, _sheet, _picked, _running) do
    %{id: "plan", label: "Plan", icon: "pi-list-checks", line: "Not saved yet", saved_at: nil, tone: :empty}
  end

  defp plan_item(plan, sheet, picked, running) do
    {line, saved_at, tone} =
      cond do
        picked == nil or (plan.design != nil and plan.design.key == picked.key) -> {files(sheet), plan.saved_at, :done}
        running -> {"Revising for the pick", nil, :working}
        plan.design == nil -> {"Written before the pick", nil, :stale}
        true -> {"Written for #{plan.design.title}, not #{picked.title}", nil, :stale}
      end

    %{id: "plan", label: "Plan", icon: "pi-list-checks", line: line, saved_at: saved_at, tone: tone}
  end

  defp files(%{files: files}), do: "#{length(files)} #{if length(files) == 1, do: "file", else: "files"}"
  defp files(nil), do: nil

  # The acceptance criteria are the list under the heading that names them.
  defp criteria(description) do
    description
    |> String.split("\n")
    |> Enum.drop_while(&(not Regex.match?(~r/^#+\s+acceptance criteria/i, &1)))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.starts_with?(&1, "#")))
    |> Enum.count(&Regex.match?(~r/^\s?([-*+]|\d+\.)\s+\S/, &1))
  end

  # What waits on the human opens first: a pick, then whatever Plan is working on or stopped short of.
  defp default_item(items, ticket, plan) do
    by_id = Map.new(items, &{&1.id, &1})

    cond do
      by_id["design"].tone in [:pick, :failed] -> "design"
      by_id["plan"].tone in [:working, :stale] -> "plan"
      ticket == nil -> "ticket"
      by_id["design"].tone == :working -> "design"
      plan != nil and by_id["design"].tone == :skipped -> "ticket"
      true -> "plan"
    end
  end

  defp banner(nil, _picked, _running), do: nil
  defp banner(_plan, nil, _running), do: nil
  defp banner(%{design: %{key: key}}, %{key: key}, _running), do: nil

  defp banner(plan, picked, running) do
    written = if plan.design, do: "the plan written for #{plan.design.title}", else: "the plan written before the pick"
    prefix = if running, do: "Being revised for #{picked.title}.", else: "Not yet revised for #{picked.title}."
    "#{prefix} Below is #{written}."
  end

  defp pending_text(true, _pick_up) do
    "Architect is reading the ticket and the code it touches, then writing the plan an engineer builds from. It appears here as soon as it is saved."
  end

  defp pending_text(false, pick_up), do: "Plan stopped before saving a plan. " <> pick_up

  # A run with no conversation, such as one moved here when Plan shipped, starts again from its brief.
  defp pick_up(run) do
    if Run.resumable?(run),
      do: "Send it a message in the conversation to pick up where it left off.",
      else: "Retry it from the conversation to start it again from its brief."
  end

  # The pick, once there is one; otherwise the option being looked at, while it still exists.
  defp selected_key(nil, _selected), do: nil
  defp selected_key(%{picked: picked}, _selected) when is_binary(picked), do: picked

  defp selected_key(%{options: options}, selected) do
    (Enum.find(options, &(&1.key == selected)) || List.first(options) || %{key: nil}).key
  end

  defp shown_option(nil, _key), do: nil
  defp shown_option(%{options: options}, key), do: Enum.find(options, &(&1.key == key))

  # The slots left of three: still being built while Plan works, not saved once it has stopped.
  defp slots(%{picked: nil, options: options}, running) when length(options) < 3 do
    for number <- (length(options) + 1)..3//1, do: %{number: number, state: if(running, do: :building, else: :missing)}
  end

  defp slots(_design, _running), do: []

  defp status_class(:pick), do: "text-amber-600 dark:text-amber-300"
  defp status_class(:failed), do: "text-red-600 dark:text-red-300"
  defp status_class(:stale), do: "text-amber-600 dark:text-amber-300"
  defp status_class(_tone), do: "text-slate-500 dark:text-slate-400"

  defp mark(:done), do: %{icon: "pi-check-circle-fill", class: "text-emerald-500 dark:text-emerald-400"}
  defp mark(:pick), do: %{icon: "pi-hand-pointing-fill", class: "text-amber-500 dark:text-amber-300"}
  defp mark(:failed), do: %{icon: "pi-warning-circle-fill", class: "text-red-500 dark:text-red-400"}
  defp mark(:stale), do: %{icon: "pi-warning-circle", class: "text-amber-500 dark:text-amber-300"}
  defp mark(:skipped), do: %{icon: "pi-minus-circle", class: "text-slate-400 dark:text-slate-500"}
  defp mark(:empty), do: %{icon: "pi-circle-dashed", class: "text-slate-400 dark:text-slate-500"}

  defp respond({:ok, _run}, socket) do
    send(self(), :task_changed)
    {:noreply, assign(socket, :error, nil)}
  end

  # A refusal usually means the task moved under the page, so the page reads it again.
  defp respond({:error, reason}, socket) do
    send(self(), :task_changed)
    {:noreply, assign(socket, :error, message_for(reason))}
  end

  defp message_for(:stage_running), do: "Something is still running on this task."
  defp message_for({:invalid_stage, stage}), do: "This task is at #{Task.stage_label(stage)}, not Plan."
  defp message_for(:no_ticket), do: "Plan has not saved a ticket yet."
  defp message_for(:no_plan), do: "Plan has not saved a plan yet."
  defp message_for(:nothing_picked), do: "Pick a design before approving."
  defp message_for(:plan_not_for_pick), do: "The plan is not written for the picked design yet."
  defp message_for(:screenshot_missing), do: "The picked design has no screenshot yet."
  defp message_for(:stale_screenshot), do: "The screenshot is older than the design. Ask Plan to retake it."
  defp message_for(:already_picked), do: "A design has already been picked."
  defp message_for(:design_not_found), do: "No design options are saved yet."
  defp message_for(:option_not_found), do: "That design option no longer exists."
  defp message_for(:chat_unavailable), do: "Plan cannot be messaged yet."
  defp message_for(:design_not_picked), do: "Pick a design to comment on it."
  defp message_for(:not_the_pick), do: "Only the picked design takes comments."
  # coveralls-ignore-start (a refusal nobody has written a sentence for yet)
  defp message_for(reason), do: "Could not update the plan: #{inspect(reason)}"
  # coveralls-ignore-stop
end
