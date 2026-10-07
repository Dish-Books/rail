defmodule RailWeb.Live.PlanStage do
  @moduledoc """
  The Plan step: the ticket, the design options, the plan and the split, a list of four with the selected
  one beside it, and the one Approve in the header. A child of a split shows only its approved part.

  Everything here is read off scratch and the runs whenever the page reloads it, so a save shows
  the moment it lands. What waits on the human opens when the step opens, and only a click changes it after.
  """
  use RailWeb, :live_component

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:selected_key, fn -> nil end)
      |> assign_new(:diagram_views, fn -> %{change: :diagram, call_flow: :diagram} end)
      |> assign_new(:open_child, fn -> nil end)
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
        status={@status}
        flush
      >
        <:breadcrumb :if={@breadcrumb != []}>{render_slot(@breadcrumb)}</:breadcrumb>
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

        <.child_plan_pane
          :if={@child_of}
          child_of={@child_of}
          plan={@plan}
          sheet={@sheet}
          diagram_views={@diagram_views}
          target={@myself}
        />

        <div :if={!@child_of} class="@container h-full">
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

              <.split_pane
                :if={@selected_item == "split"}
                split={@split}
                open_child={@open_child}
                diagram_views={@diagram_views}
                target={@myself}
              />
            </div>
          </div>
        </div>

        <:sidebar :if={!@child_of}>{render_slot(@sidebar)}</:sidebar>
      </.task_layout>
    </div>
    """
  end

  @impl true
  def handle_event("select_item", %{"item" => item}, socket) when item in ["ticket", "design", "plan", "split"] do
    {:noreply, assign(socket, :selected_item, item)}
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

  # A card opens to its child's whole ticket and part of the plan; opening it again closes it.
  def handle_event("open_child", %{"number" => number}, socket) do
    number = String.to_integer(number)
    {:noreply, assign(socket, :open_child, if(socket.assigns.open_child == number, do: nil, else: number))}
  end

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
        <div
          id={"design-frame-#{@option.key}"}
          phx-hook="DesignFrame"
          class="relative w-full aspect-video overflow-hidden rounded-xl border border-slate-200 dark:border-slate-700 bg-white"
        >
          <iframe
            :if={@option.html != nil}
            id={"design-page-#{@option.key}-#{@option.html_version}"}
            title={@option.title}
            sandbox="allow-scripts"
            src={~p"/tasks/#{@task.id}/design/#{@option.key}?v=#{@option.html_version}"}
            class="absolute top-0 left-0 w-full h-full border-0"
          />
          <p
            :if={@option.html == nil}
            class="absolute inset-0 flex items-center justify-center text-xs text-slate-400"
          >
            This option has no page yet.
          </p>
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

  attr :split, :any, required: true
  attr :open_child, :integer, default: nil
  attr :diagram_views, :map, default: %{}
  attr :target, :any, default: nil

  defp split_pane(%{split: nil} = assigns) do
    ~H"""
    <div
      id="plan-split-none"
      data-qa="plan_split_none"
      class="flex flex-col items-center text-center max-w-md mx-auto py-14"
    >
      <div class="flex items-center justify-center size-14 rounded-2xl bg-slate-100 dark:bg-slate-800 text-slate-400 ring-1 ring-slate-200 dark:ring-slate-700">
        <.icon name="pi-arrows-split" class="size-7" />
      </div>
      <h2 class="mt-5 text-base font-semibold text-slate-900 dark:text-slate-100">Not split</h2>
      <p class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">
        Approve makes one task, which moves to Engineer. Ask Plan for a split when the work is too big for one ticket.
      </p>
    </div>
    """
  end

  defp split_pane(assigns) do
    children = Enum.map(assigns.split.children, &Map.put(&1, :first_file, first_file(&1.plan)))
    open = Enum.find(assigns.split.children, &(&1.number == assigns.open_child))

    assigns =
      assigns
      |> assign(:rounds, rounds(children))
      |> assign(:open, open)
      |> assign(:open_sheet, open && build_plan_sheet(open.plan))

    ~H"""
    <div id="plan-split" data-qa="plan_split" class="@container">
      <div class="flex items-baseline gap-3 mb-4">
        <h2 class="text-xl font-bold text-slate-900 dark:text-slate-100">
          Split into {length(@split.children)} children
        </h2>
        <span class="text-sm text-slate-500 dark:text-slate-400">
          {points(@split.children)} · {length(@rounds)} {if length(@rounds) == 1,
            do: "round",
            else: "rounds"}
        </span>
      </div>

      <div class="grid @3xl:grid-cols-3 gap-5 items-start">
        <div :for={{label, children} <- @rounds} data-qa="plan_split_round" class="min-w-0 space-y-2">
          <p class="px-1 text-[11px] font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
            {label}
          </p>
          <div
            :for={child <- children}
            id={"plan-split-child-#{child.number}"}
            data-qa="plan_split_child"
            class="rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900/60 p-3.5 space-y-2.5 min-w-0"
          >
            <div class="flex items-start gap-2.5">
              <span class="flex items-center justify-center size-6 shrink-0 rounded-full bg-slate-100 dark:bg-slate-800 font-mono text-xs text-slate-600 dark:text-slate-300">
                {child.number}
              </span>
              <p class="min-w-0 flex-1 text-[13.5px] font-semibold leading-snug text-slate-900 dark:text-slate-100 wrap-break-word">
                {child.title}
              </p>
              <span
                :if={child.estimate}
                title="Estimate"
                class="shrink-0 inline-flex items-center gap-1 h-6 px-2 rounded-full border border-slate-200 dark:border-slate-700 text-xs text-slate-600 dark:text-slate-300"
              >
                <.icon name="pi-triangle" class="size-[11px] text-slate-500" />{child.estimate}
              </span>
            </div>
            <p
              id={"plan-split-child-#{child.number}-order"}
              class="text-[11.5px] text-slate-500 dark:text-slate-400"
            >
              {if child.builds_on == [],
                do: "starts at once",
                else: "after " <> join_and(child.builds_on)}
            </p>
            <p class="text-[12.5px] leading-relaxed text-slate-600 dark:text-slate-300 line-clamp-2 wrap-break-word">
              {first_paragraph(child.ticket)}
            </p>
            <p class="text-[11.5px] text-slate-500 dark:text-slate-400">
              {count_label(criteria(child.ticket), "criterion", "criteria")}
            </p>
            <div :if={child.first_file} class="pt-2 border-t border-slate-200 dark:border-slate-800">
              <p class="font-mono text-[11.5px] text-slate-700 dark:text-slate-300 truncate">
                {child.first_file.path}
              </p>
              <p :if={child.first_file.more > 0} class="font-mono text-[11.5px] text-slate-500">
                + {child.first_file.more} more
              </p>
            </div>
            <button
              type="button"
              id={"plan-split-child-#{child.number}-open"}
              aria-expanded={to_string(@open_child == child.number)}
              aria-controls="plan-split-child-detail"
              phx-click="open_child"
              phx-value-number={child.number}
              phx-target={@target}
              class="text-[12.5px] font-semibold text-blue-600 dark:text-blue-400 hover:underline cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 rounded"
            >
              {if @open_child == child.number,
                do: "Hide the ticket and plan",
                else: "Read the ticket and plan"}
            </button>
          </div>
        </div>
      </div>

      <section
        :if={@open}
        id="plan-split-child-detail"
        data-qa="plan_split_child_detail"
        class="mt-6 rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900/60 p-5 space-y-6 select-text"
      >
        <h3 class="text-lg font-bold text-slate-900 dark:text-slate-100 wrap-break-word">
          {@open.number}. {@open.title}
        </h3>
        <div>
          <p class="mb-2 text-[11px] font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
            Ticket
          </p>
          <.markdown content={@open.ticket} class="text-[15px] leading-relaxed" />
        </div>
        <div>
          <p class="mb-2 text-[11px] font-semibold uppercase tracking-wider text-slate-500 dark:text-slate-400">
            Part of the plan
          </p>
          <.plan_sheet
            :if={@open_sheet}
            sheet={@open_sheet}
            diagram_views={@diagram_views}
            event="diagram_view"
            target={@target}
          />
          <.markdown
            :if={@open_sheet == nil}
            content={@open.plan}
            class="text-[15px] leading-relaxed"
          />
        </div>
      </section>
    </div>
    """
  end

  attr :child_of, :map, required: true
  attr :plan, :any, required: true
  attr :sheet, :any, required: true
  attr :diagram_views, :map, required: true
  attr :target, :any, required: true

  # A child never runs Plan: its plan is the part of its parent's it was approved with.
  defp child_plan_pane(assigns) do
    ~H"""
    <div id="child-plan" data-qa="child_plan" class="h-full overflow-y-auto px-6 py-6">
      <div
        :if={@child_of.waiting_on != []}
        id="child-plan-waiting"
        data-qa="child_plan_waiting"
        class="mb-5 flex items-center gap-2.5 rounded-lg border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 px-4 py-2.5 text-[13px] text-slate-600 dark:text-slate-300"
      >
        <.icon name="pi-clock" class="size-4 text-slate-500" />
        <span class="min-w-0 wrap-break-word">
          Starts when
          <span :for={{identifier, index} <- Enum.with_index(@child_of.waiting_on)}>
            <span :if={index > 0}>{if index == length(@child_of.waiting_on) - 1,
              do: " and ",
              else: ", "}</span><.link
              patch={~p"/tasks/#{@child_of.parent.id}?child=#{identifier}"}
              class="font-mono font-semibold text-blue-600 dark:text-blue-400 hover:underline"
            >{identifier}</.link>
          </span>
          {if length(@child_of.waiting_on) == 1, do: "merges", else: "merge"}.
        </span>
      </div>

      <p
        id="child-plan-approved"
        class="mb-4 inline-flex items-center gap-1.5 text-xs font-semibold text-emerald-600 dark:text-emerald-400"
      >
        <.icon name="pi-check-circle" class="size-4" />
        Approved in {@child_of.parent.issue.identifier} · part {@child_of.position} of {@child_of.total}
      </p>

      <div :if={@plan} class={["select-text", @sheet == nil && "max-w-3xl"]}>
        <.plan_sheet
          :if={@sheet}
          sheet={@sheet}
          diagram_views={@diagram_views}
          event="diagram_view"
          target={@target}
        />
        <.markdown :if={@sheet == nil} content={@plan.content} class="text-[15px] leading-relaxed" />
      </div>
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
    split = Pipeline.read_split(task)
    running = Run.running?(run)
    picked = design && Enum.find(design.options, &(&1.key == design.picked))
    selected_key = selected_key(design, socket.assigns.selected_key)
    items = items(ticket, design, picked, plan, split, running)

    socket
    |> assign(:ticket, ticket)
    |> assign(:design, design)
    |> assign(:plan, plan)
    |> assign(:split, split)
    |> assign(:sheet, plan && build_plan_sheet(plan.content))
    |> assign(:approved, approved)
    |> assign(:running, running)
    |> assign(:can_pick, task.stage == :plan and Run.can_chat?(run))
    |> assign(:selected_key, selected_key)
    |> assign(:option, shown_option(design, selected_key))
    |> assign(:items, items)
    |> assign_new(:selected_item, fn -> default_item(items, ticket, plan, split) end)
    |> assign(:banner, banner(plan, picked, running))
    |> assign(:pick_up, pick_up(run))
    |> assign(:pending_text, pending_text(running, pick_up(run)))
    |> assign(:show_approve, approvable?(socket.assigns, ticket, design, plan))
  end

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

  defp items(ticket, design, picked, plan, split, running) do
    options = if design, do: design.options, else: []
    plan_sheet = plan && build_plan_sheet(plan.content)

    [
      ticket_item(ticket, running),
      design_item(options, picked, plan, running),
      plan_item(plan, plan_sheet, picked, running),
      split_item(split)
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

  defp split_item(nil) do
    %{id: "split", label: "Split", icon: "pi-arrows-split", line: "Not split: one task", saved_at: nil, tone: :skipped}
  end

  defp split_item(%{children: children, saved_at: saved_at}) do
    line = "#{length(children)} children · #{points(children)}"
    %{id: "split", label: "Split", icon: "pi-arrows-split", line: line, saved_at: saved_at, tone: :done}
  end

  defp points(children) do
    children |> Enum.map(&(&1.estimate || 0)) |> Enum.sum() |> count_label("point", "points")
  end

  defp count_label(count, one, many), do: "#{count} #{if count == 1, do: one, else: many}"

  # Each child sits in the round after the latest of the ones it builds on, so a lane starts together.
  defp rounds(children) do
    round_of =
      Enum.reduce(children, %{}, fn child, rounds ->
        Map.put(rounds, child.number, Enum.max(Enum.map(child.builds_on, &(rounds[&1] + 1)), fn -> 0 end))
      end)

    children
    |> Enum.group_by(&round_of[&1.number])
    |> Enum.sort()
    |> Enum.map(fn
      {0, lane} ->
        {"Starts at once", lane}

      {_round, lane} ->
        {"After " <> (lane |> Enum.flat_map(& &1.builds_on) |> Enum.uniq() |> Enum.sort() |> join_and()), lane}
    end)
  end

  defp join_and([one]), do: "#{one}"
  defp join_and(numbers), do: Enum.join(Enum.drop(numbers, -1), ", ") <> " and #{List.last(numbers)}"

  defp first_paragraph(ticket), do: ticket |> String.split(~r/\n\s*\n/, parts: 2) |> hd()

  defp first_file(plan) do
    case build_plan_sheet(plan) do
      %{files: [first | rest]} -> %{path: first.path, more: length(rest)}
      _no_sheet -> nil
    end
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
  defp default_item(items, ticket, plan, split) do
    by_id = Map.new(items, &{&1.id, &1})

    cond do
      by_id["design"].tone in [:pick, :failed] -> "design"
      by_id["plan"].tone in [:working, :stale] -> "plan"
      ticket == nil -> "ticket"
      by_id["design"].tone == :working -> "design"
      split != nil -> "split"
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
  # coveralls-ignore-start (a refusal nobody has written a sentence for yet)
  defp message_for(reason), do: "Could not update the plan: #{inspect(reason)}"
  # coveralls-ignore-stop
end
