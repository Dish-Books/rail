defmodule RailWeb.Live.TaskDetail do
  @moduledoc """
  A task's page body: the header with every decision on it, and a slim rail of the task's items beside the picked
  one. Issue and Plan are the page's own, handed in as slots, and the conversation is too. A custom stage of a
  workflow's task is an item of its own, its file beside its conversation, with Approve in the header. Plan reads every round
  beside it, with the next one's plan and its Approve while it waits, and every other item has its trays under it. Findings is the list beside one finding, with what the round's agents are doing
  above them; ruling moves on to the next finding. What Send would send and whether it can is handed to the page
  for the conversation's tray. Diff is the branch, or one commit of it, which a finding's commits open. Screens is
  each screen state's one shot, opened over the page to step through and comment on, Demo plays the latest
  recording with its walkthrough and says when the branch has moved past it, and Browser watches QA's browser.
  Comments lists every comment on the task, and each opens where it was left.
  """
  use RailWeb, :live_component

  import RailWeb.Utils.BuildFixPlanLines
  import RailWeb.Utils.CalculateDocumentComments
  import RailWeb.Utils.CustomStageItem
  import RailWeb.Utils.MonotonicMs
  import RailWeb.Utils.StageLabel, only: [custom_stage_waiting?: 2]

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.FindingEvidence
  alias Rail.Pipeline.Schemas.FindingPlace
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Users
  alias RailWeb.Live.CustomStage
  alias RailWeb.Live.DiffView

  @double_click_ms 400
  @no_code %{where: nil, places: %{}, where_place: nil}

  # The conversation's tray asked for a finding or a screen state, which this stage shows.
  @impl true
  def update(%{open_finding: key}, socket) do
    socket = socket |> pick(:findings) |> assign(:selected_key, key) |> assign(:filed_index, 0) |> load()
    {:ok, socket}
  end

  def update(%{open_screen: key}, socket) do
    socket = socket |> pick(:screens) |> open_screen(key) |> load()
    {:ok, socket}
  end

  # Something the page heard moved what the stage shows; it reads it again off the task it holds.
  def update(%{reload: true}, socket), do: {:ok, load(socket)}

  # A comment in the Comments item opens the Plan item. Round 1 is the Plan stage, whose round the URL keeps.
  def update(%{open_plan: nil}, socket) do
    socket = socket |> pick(:plan) |> assign(:plan_round, nil) |> load()
    {:ok, socket}
  end

  def update(%{open_plan: round}, socket) do
    send(self(), {:plan_round, round})
    socket = socket |> assign(:item, :plan) |> assign(:plan_round, round) |> load()
    {:ok, socket}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> open_url_item(assigns)
      |> open_url_file(assigns)
      |> assign(assigns)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:selected_key, fn -> nil end)
      |> assign_new(:plan_round, fn -> assigns[:url_round] end)
      |> assign_new(:advanced_to, fn -> nil end)
      |> assign_new(:filed_index, fn -> 0 end)
      |> assign_new(:browser, fn -> nil end)
      |> assign_new(:diff_open, fn -> nil end)
      |> assign_new(:diff_file, fn -> nil end)
      |> assign_new(:screen_open, fn -> nil end)
      |> assign_new(:screen_draft, fn -> nil end)
      |> assign_new(:finding_draft, fn -> nil end)
      |> assign_new(:fix_plan_draft, fn -> nil end)
      |> assign_new(:comment_order, fn -> "newest" end)
      |> assign_new(:reported_lifted, fn -> nil end)
      |> assign_new(:code_cache, fn -> %{fingerprint: :unread, by_key: %{}} end)
      |> load()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="task-detail" data-qa="task-detail" class="contents">
      <.task_layout
        task={@task}
        run={@stage_run}
        stage_run={@stage_run}
        line={@line}
        title={@task.issue.title}
        status={@status}
        link_workflow={Scope.admin?(@current_scope)}
        flush
      >
        <:breadcrumb :if={@breadcrumb != []}>{render_slot(@breadcrumb)}</:breadcrumb>
        <:actions>
          {render_slot(@actions)}

          <button
            :if={@show_approve}
            type="button"
            id="approve-fix-plan"
            data-qa="approve_fix_plan"
            phx-click="approve_fix_plan"
            phx-value-version={@fix_plan.version}
            phx-target={@myself}
            phx-disable-with="Starting…"
            class="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg text-sm font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs disabled:opacity-60 disabled:cursor-not-allowed focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <%!-- Not the PR's Approve, which sits in the same place at Finalize --%>
            <.icon name="pi-play" class="size-4" /> Start fix round
          </button>

          <button
            :if={@stage_approvable}
            type="button"
            id="approve-custom-stage"
            data-qa="approve_custom_stage"
            phx-click="approve_stage_output"
            phx-target={@myself}
            phx-disable-with="Approving…"
            disabled={@stage_unsent > 0}
            title={@stage_unsent > 0 && unsent(@stage_unsent)}
            class="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg text-sm font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs disabled:opacity-60 disabled:cursor-not-allowed focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
          >
            <.icon name="pi-check" class="size-4" /> Approve
          </button>
        </:actions>

        <:alerts :if={@error}>
          <p id="review-error" data-qa="review_error" class="text-xs text-red-600 dark:text-red-500">
            <span :if={is_binary(@error)}>{@error}</span>
            <span :if={match?({:replaced, _at}, @error)}>
              That fix plan was replaced at
              <.local_time
                id="review-error-replaced-at"
                at={elem(@error, 1)}
              />. Nothing started. Read the plan on screen, then start the round.
            </span>
          </p>
        </:alerts>

        <div class="@container h-full">
          <div class="h-full flex flex-col @xl:flex-row min-h-0">
            <.review_items
              items={@items}
              picked={if @item == :fix_plan, do: :plan, else: @item}
              target={@myself}
            />

            <div
              id="review-pane"
              data-item={@item}
              class="flex-1 min-w-0 min-h-0 flex flex-col @5xl:flex-row"
            >
              <%!-- The plan is read beside its conversation, so a comment and the reply to it are both in view. --%>
              <%!-- Its edge drags it wider, and the width the hook sets is kept through patches. A split's child
              waiting on its turn has run nothing, so it has no conversation to show. --%>
              <aside
                :if={@beside and @task.runs != []}
                id="plan-chat"
                data-qa="plan_chat"
                phx-hook="SidebarResize"
                phx-mounted={JS.ignore_attributes(["style"])}
                class="relative order-last @5xl:order-first shrink-0 h-[45%] @5xl:h-auto @5xl:w-[var(--sidebar-width,400px)] min-h-0 flex flex-col border-t @5xl:border-t-0 @5xl:border-r border-slate-200 dark:border-slate-700"
              >
                {render_slot(@conversation)}
                <div
                  data-resize-handle
                  role="separator"
                  aria-orientation="vertical"
                  aria-label="Resize the conversation"
                  aria-valuemin="280"
                  tabindex="0"
                  class="hidden @5xl:block absolute inset-y-0 -right-1 w-2 z-10 cursor-col-resize hover:bg-blue-500/30 focus-visible:bg-blue-500/40 focus-visible:outline-none"
                />
              </aside>

              <div class="flex-1 min-w-0 min-h-0 flex flex-col">
                <form
                  :if={@item in [:plan, :fix_plan] and length(@round_options) > 1}
                  id="plan-rounds"
                  phx-change="pick_round"
                  phx-target={@myself}
                  class="shrink-0 flex items-center gap-2 px-5 py-2 border-b border-slate-200 dark:border-slate-700"
                >
                  <label
                    for="plan-round-select"
                    class="text-xs font-semibold text-slate-500 dark:text-slate-400"
                  >
                    Round
                  </label>
                  <select
                    id="plan-round-select"
                    name="round"
                    class="rounded-md border-slate-300 dark:border-slate-600 bg-white dark:bg-slate-800 py-1 pl-2 pr-8 text-xs font-semibold text-slate-800 dark:text-slate-100"
                  >
                    <option
                      :for={{value, label} <- @round_options}
                      value={value}
                      selected={value == @round_pick}
                    >
                      {label}
                    </option>
                  </select>
                </form>
                <div
                  :if={@item == :issue}
                  id="task-item-issue"
                  class="flex-1 min-h-0 overflow-y-auto px-6 py-8"
                >
                  {render_slot(@issue)}
                </div>
                <div
                  :if={@item == :plan and @round_pick == "1"}
                  id="task-item-plan"
                  class="flex-1 min-h-0"
                >
                  {render_slot(@plan)}
                </div>
                <.round_plan :if={@item == :plan and @round_pick != "1"} round={@shown_round} />
                <div :if={@custom_item} id="task-item-custom-stage" class="flex-1 min-h-0">
                  <.live_component
                    module={CustomStage}
                    id={"custom-#{@custom_item.key}"}
                    task={@task}
                    run={@custom_item.run}
                    name={@custom_item.name}
                    current_scope={@current_scope}
                  />
                </div>
                <div
                  :if={@item == :children}
                  id="task-item-children"
                  class="flex-1 min-h-0 overflow-y-auto px-6 py-8"
                >
                  {render_slot(@children)}
                </div>
                <.review_status
                  :if={
                    @item == :findings and
                      @phase in [
                        :round,
                        :planning,
                        :waiting,
                        :outdated,
                        :fixing,
                        :blocked,
                        :stalled,
                        :ci,
                        :ci_failed,
                        :finished
                      ]
                  }
                  phase={@phase}
                  round={@round}
                  revising={@revising}
                  target={@myself}
                  sha={@sha}
                  counts={@counts}
                  agents={@agents}
                  pr_number={@task.pr_number}
                  work={@work}
                  base={@task.project.default_branch}
                  question={@engineer.question}
                  error={@engineer.error}
                />

                <div :if={@item == :findings} class="@container flex-1 min-h-0">
                  <div class="h-full flex flex-col @2xl:flex-row min-h-0">
                    <.finding_list
                      findings={@findings}
                      selected_key={@selected_key}
                      running={@phase == :round}
                      tally={@tally}
                      changed={Map.new(@ruling_changes.since_plan, &{&1.key, &1.now})}
                      target={@myself}
                    />
                    <.finding_detail
                      :if={@selected}
                      finding={@selected}
                      position={@position}
                      count={length(@findings)}
                      decidable={
                        @approvable and @phase not in [:round, :planning, :fixing, :ci, :finished]
                      }
                      ruling_was={
                        Enum.find_value(
                          @ruling_changes.since_plan,
                          &(&1.key == @selected.key && &1.was)
                        )
                      }
                      running={@phase == :round}
                      where_code={@code.where}
                      place_codes={@code.places}
                      where_place={@code.where_place}
                      head={@head}
                      filed={@filed}
                      filed_index={@filed_index}
                      labels={@labels}
                      names={@names}
                      viewer_id={@current_scope.user && @current_scope.user.id}
                      suppressor={@suppressor}
                      neighbours={@neighbours}
                      comments={@finding_placed}
                      draft={@finding_draft}
                      offered={@commentable}
                      target={@myself}
                    />
                    <p
                      :if={@selected == nil}
                      id="review-no-findings"
                      data-qa="review_no_findings"
                      class="flex-1 p-8 text-sm text-slate-500 dark:text-slate-400"
                    >
                      {if @phase == :round,
                        do: "Findings appear here as the round saves them.",
                        else: "No findings."}
                    </p>
                  </div>
                </div>

                <div
                  :if={@item == :fix_plan}
                  id="fix-plan-pane"
                  class="flex-1 min-w-0 min-h-0 overflow-y-auto px-5 py-5 @3xl:px-8 @3xl:py-6"
                >
                  <div
                    :if={@fix_plan.plan == nil}
                    id="fix-plan-empty"
                    class="flex flex-col items-center text-center max-w-md mx-auto py-14"
                  >
                    <div class="relative flex items-center justify-center size-14 rounded-2xl bg-slate-100 dark:bg-slate-800 text-slate-400 ring-1 ring-slate-200 dark:ring-slate-700">
                      <.icon name="pi-clipboard-text" class="size-7" />
                      <span
                        :if={Run.running?(@run)}
                        class="absolute -bottom-1 -right-1 size-4 rounded-full border-2 border-slate-300 dark:border-slate-600 border-t-blue-500 motion-safe:animate-spin bg-white dark:bg-slate-900"
                      />
                    </div>
                    <h2 class="mt-5 text-base font-semibold text-slate-900 dark:text-slate-100">
                      {if Run.running?(@run), do: "Writing the fix plan", else: "No fix plan"}
                    </h2>
                    <p class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">
                      {if Run.running?(@run),
                        do:
                          "On #{asked(@fix_plan)}. Approve appears in the header once the plan is saved.",
                        else:
                          "The lead stopped before it saved one, and nothing changed in the worktree. Message the lead to write it."}
                    </p>
                  </div>

                  <div :if={@fix_plan.plan}>
                    <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1 mb-5">
                      <h2 class="text-xl font-bold text-slate-900 dark:text-slate-100">Fix plan</h2>
                      <span class="text-sm text-slate-500 dark:text-slate-400">
                        Fix round {@fix_plan.round} · saved
                        <.local_time id="fix-plan-saved-at" at={@fix_plan.saved_at} />
                      </span>
                    </div>

                    <div
                      :if={@revising}
                      id="fix-plan-revising"
                      class="mb-5 flex items-center gap-2.5 rounded-lg border border-blue-200 dark:border-blue-900 bg-blue-50 dark:bg-blue-950/40 px-4 py-2.5 text-[13px] text-blue-800 dark:text-blue-200"
                    >
                      <span
                        :if={Run.running?(@run)}
                        class="size-3 shrink-0 rounded-full border-2 border-slate-300 dark:border-slate-600 border-t-blue-500 motion-safe:animate-spin"
                      />
                      <span class="min-w-0">
                        {if Run.running?(@run),
                          do:
                            "Revising on #{@revising}. This plan is replaced when the lead saves the new one, and Approve comes back then.",
                          else:
                            "The lead stopped before it saved the revised plan, so there is nothing to approve. Message the lead to save it."}
                      </span>
                    </div>

                    <div
                      :if={@plan_state == :outdated and not Run.running?(@run)}
                      id="fix-plan-outdated"
                      class="mb-5 flex items-start gap-2.5 rounded-lg border border-amber-300 dark:border-amber-800/70 bg-amber-50 dark:bg-amber-950/30 px-4 py-2.5 text-[13px] text-amber-900 dark:text-amber-200"
                    >
                      <.icon name="pi-swap" class="size-4 mt-0.5 shrink-0" />
                      <span class="min-w-0 wrap-anywhere">
                        <span class="font-semibold">Out of date.</span>
                        <span :for={{change, index} <- Enum.with_index(@ruling_changes.since_plan)}>{separator(
                          index,
                          length(@ruling_changes.since_plan)
                        )}<code class="font-mono text-[12px]">{change.key}</code>
                        changed from {ruling(change.was)} to {ruling(change.now)}</span>
                        after this plan was saved. Send the change from the tray for a revised plan, or change it back to approve this one.
                      </span>
                    </div>

                    <div class={[@plan_state not in [:waiting, :approved] && "opacity-70"]}>
                      <.fix_plan_sheet
                        sheet={FixPlan.build_sheet(@fix_plan)}
                        changed={Map.new(@ruling_changes.since_plan, &{&1.key, &1.now})}
                        placed={@fix_plan_comments.placed}
                        lifted={@fix_plan_comments.lifted}
                        draft={@fix_plan_draft}
                        offered={@fix_plan_offered}
                        reviewed={@fix_plan_reviewed}
                        default_paths={@fix_plan_default_paths}
                        diff_paths={@fix_plan_diff_paths}
                        project={@task.project}
                        target={@myself}
                      />
                    </div>
                  </div>
                </div>

                <div :if={@item == :diff} class="flex-1 min-w-0 min-h-0">
                  <.live_component
                    module={DiffView}
                    id="diff-view"
                    task={@task}
                    current_scope={@current_scope}
                    focus_file={@diff_file}
                    open={@diff_open}
                  />
                </div>

                <.screen_grid
                  :if={@item == :screens}
                  task_id={@task.id}
                  screens={@screens}
                  labels={@labels}
                  unsent={@unsent_screens}
                  target={@myself}
                />

                <.comment_list
                  :if={@item == :comments}
                  comments={
                    if @comment_order == "newest", do: Enum.reverse(@comments), else: @comments
                  }
                  order={@comment_order}
                  screen_keys={Enum.map(@screens, & &1.key)}
                  reader_id={@current_scope.user.id}
                  target={@myself}
                />

                <.demo_player
                  :if={@item == :demo}
                  task={@task}
                  demo={@demo}
                  beats={@beats}
                  recorded={@recorded}
                  recording={@recording}
                  stale={@stale}
                  rerecordable={@approvable and not Run.running?(@run)}
                  off={Issue.skips_step?(@task.issue, :demo)}
                  target={@myself}
                />

                <.browser_picker
                  :if={@item == :browser}
                  sessions={@sessions}
                  picked={@browser}
                  url={@url}
                  beats={length(@beats)}
                  target={@myself}
                />

                <%!-- Under every other item, the comments waiting to be sent, so Send is never an item away. --%>
                <div :if={!@beside} class="shrink-0">
                  {render_slot(@conversation)}
                </div>
              </div>
            </div>
          </div>
        </div>
      </.task_layout>

      <.screen_view
        :if={@opened}
        task_id={@task.id}
        screen={@opened.screen}
        position={@opened.position}
        count={length(@screens)}
        labels={@labels}
        comments={@opened.comments}
        draft={@screen_draft}
        target={@myself}
      />
    </div>
    """
  end

  @impl true
  # Plan opens on the latest round: the next one's plan while it waits on approval.
  def handle_event("pick_item", %{"item" => "plan"}, socket) do
    item = if waiting_plan?(socket.assigns), do: :fix_plan, else: :plan
    socket = socket |> pick(item) |> assign(:plan_round, nil) |> load()
    {:noreply, socket}
  end

  def handle_event("pick_item", %{"item" => item}, socket) do
    socket = socket |> pick(item(item, socket.assigns.task) || :findings) |> load()
    {:noreply, socket}
  end

  def handle_event("pick_round", %{"round" => "next"}, socket) do
    socket = socket |> pick(:fix_plan) |> load()
    {:noreply, socket}
  end

  # The URL names the round, so a refresh comes back to it.
  def handle_event("pick_round", %{"round" => round}, socket) do
    send(self(), {:plan_round, round})
    socket = socket |> assign(:item, :plan) |> assign(:plan_round, round) |> load()
    {:noreply, socket}
  end

  # A finding's commit opens in the Diff item at the finding's file; none is the whole branch.
  def handle_event("open_diff", params, socket) do
    socket =
      socket
      |> pick(:diff)
      |> assign(:diff_open, %{commit: params["commit"], at: System.unique_integer([:positive])})
      |> assign(:diff_file, params["file"])
      |> load()

    {:noreply, socket}
  end

  def handle_event("open_screen", %{"key" => key}, socket) do
    socket = socket |> open_screen(key) |> assign_opened()
    {:noreply, socket}
  end

  def handle_event("step_screen", %{"direction" => "next"}, socket), do: {:noreply, step_screen(socket, 1)}
  def handle_event("step_screen", %{"direction" => "previous"}, socket), do: {:noreply, step_screen(socket, -1)}
  def handle_event("screen_key", %{"key" => "ArrowRight"}, socket), do: {:noreply, step_screen(socket, 1)}
  def handle_event("screen_key", %{"key" => "ArrowLeft"}, socket), do: {:noreply, step_screen(socket, -1)}
  def handle_event("screen_key", _other_key, socket), do: {:noreply, socket}

  def handle_event("close_screen", _params, socket) do
    socket = socket |> open_screen(nil) |> assign_opened()
    {:noreply, socket}
  end

  def handle_event("toggle_screen_comment", _params, socket) do
    socket = socket |> assign(:screen_draft, if(socket.assigns.screen_draft, do: nil, else: "")) |> assign_opened()
    {:noreply, socket}
  end

  def handle_event("screen_comment_change", %{"body" => body}, socket) do
    {:noreply, assign(socket, :screen_draft, body)}
  end

  def handle_event("cancel_screen_comment", _params, socket) do
    socket = socket |> assign(:screen_draft, nil) |> assign_opened()
    {:noreply, socket}
  end

  # A blank comment keeps the box open, and the comment shows once the reader's list is read again.
  def handle_event("save_screen_comment", %{"body" => body}, socket) do
    %{current_scope: scope, task: task, screen_open: key} = socket.assigns

    case Pipeline.create_screen_comment(scope, task, %{"key" => key, "body" => body}) do
      {:ok, _comment} ->
        socket = socket |> assign(:screen_draft, nil) |> assign(:error, nil) |> assign_screen_comments()
        {:noreply, socket}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, :screen_draft, body)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, message_for(reason))}
    end
  end

  # Read back rather than dropped from the list, since another tab may have sent it.
  def handle_event("remove_screen_comment", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.screen_comments, &(&1.id == id)) do
      %ScreenComment{} = comment ->
        {:ok, _removed} = Pipeline.delete_screen_comment(socket.assigns.current_scope, comment)
        {:noreply, assign_screen_comments(socket)}

      nil ->
        {:noreply, socket}
    end
  end

  # The piece is read off the finding this tab shows, so only a piece it draws can be commented on.
  def handle_event("open_finding_comment", %{"piece" => piece} = params, socket) do
    %{selected: selected, commentable: commentable} = socket.assigns
    piece = Enum.find(Ecto.Enum.values(FindingComment, :piece), &(Atom.to_string(&1) == piece))

    index =
      case Integer.parse(params["index"] || "") do
        {index, ""} -> index
        _no_index -> nil
      end

    socket =
      if commentable and selected != nil and FindingComment.calculate_piece(selected, piece, index) != nil,
        do: assign(socket, :finding_draft, %{finding_id: selected.id, piece: piece, index: index, body: nil}),
        else: socket

    {:noreply, socket}
  end

  def handle_event("change_finding_comment", %{"body" => body}, %{assigns: %{finding_draft: %{} = draft}} = socket) do
    {:noreply, assign(socket, :finding_draft, %{draft | body: body})}
  end

  def handle_event("change_finding_comment", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_finding_comment", _params, socket) do
    {:noreply, assign(socket, :finding_draft, nil)}
  end

  # A blank comment keeps the box open on what was typed.
  def handle_event("save_finding_comment", %{"body" => body}, %{assigns: %{finding_draft: %{} = draft}} = socket) do
    %{current_scope: scope, task: task} = socket.assigns
    attrs = %{"finding_id" => draft.finding_id, "piece" => draft.piece, "index" => draft.index, "body" => body}

    case Pipeline.create_finding_comment(scope, task, attrs) do
      {:ok, _comment} ->
        socket = socket |> assign(:finding_draft, nil) |> assign(:error, nil) |> assign_finding_comments()
        {:noreply, socket}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, :finding_draft, %{draft | body: body})}

      {:error, :not_found} ->
        socket = socket |> assign(:finding_draft, nil) |> assign(:error, "That finding has no such piece to comment on.")
        {:noreply, socket}

      {:error, reason} ->
        socket = socket |> assign(:finding_draft, nil) |> assign(:error, message_for(reason))
        {:noreply, socket}
    end
  end

  def handle_event("save_finding_comment", _params, socket), do: {:noreply, socket}

  # Read back rather than dropped from the list, since another tab may have sent it.
  def handle_event("remove_finding_comment", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.finding_comments, &(&1.id == id)) do
      %FindingComment{} = comment ->
        {:ok, _removed} = Pipeline.delete_finding_comment(socket.assigns.current_scope, comment)
        {:noreply, assign_finding_comments(socket)}

      nil ->
        {:noreply, assign_finding_comments(socket)}
    end
  end

  # A finding the screen view cites is opened in Findings, so the view closes over it.
  def handle_event("open_finding", %{"key" => key}, socket) do
    socket =
      socket
      |> open_screen(nil)
      |> pick(:findings)
      |> assign(:selected_key, key)
      |> assign(:filed_index, 0)
      |> load()

    {:noreply, socket}
  end

  def handle_event("order_comments", %{"order" => order}, socket) when order in ["newest", "oldest"],
    do: {:noreply, assign(socket, :comment_order, order)}

  # A comment gone since the list was drawn opens nothing; the next read drops its row.
  def handle_event("open_comment", %{"kind" => kind, "id" => id}, socket) do
    case Enum.find(socket.assigns.comments, &(to_string(&1.kind) == kind and &1.id == id)) do
      %{} = entry -> {:noreply, open_comment(socket, entry)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("record_demo", _params, socket) do
    case Pipeline.record_demo(socket.assigns.current_scope, socket.assigns.task) do
      {:ok, _run} ->
        send(self(), :task_changed)
        {:noreply, assign(socket, :error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, message_for(reason))}
    end
  end

  def handle_event("pick_browser", %{"name" => name}, socket) do
    socket = socket |> assign(:browser, name) |> load()
    {:noreply, socket}
  end

  def handle_event("select_finding", %{"key" => key}, socket) do
    socket = socket |> assign(:selected_key, key) |> assign(:filed_index, 0) |> load()
    {:noreply, socket}
  end

  def handle_event("select_evidence", %{"index" => index}, socket) do
    socket = assign(socket, :filed_index, String.to_integer(index))
    {:noreply, socket}
  end

  def handle_event("decide", %{"key" => key, "decision" => decision}, socket) do
    finding = Enum.find(socket.assigns.findings, &(&1.key == key))

    # Judged before the ruling, since after it every finding looks decided and a
    # changed ruling would move the reader on too.
    selected_key =
      if Finding.undecided?(finding),
        do: (next_undecided(socket.assigns.findings, finding) || finding).key,
        else: socket.assigns.selected_key

    socket =
      with false <- double_click?(socket.assigns.advanced_to, key),
           {:ok, _decided} <- Pipeline.decide_finding(socket.assigns.current_scope, finding, decision(decision)) do
        socket
        |> assign(:error, nil)
        |> assign(:selected_key, selected_key)
        |> assign(:filed_index, 0)
        |> assign(:advanced_to, if(selected_key != key, do: {selected_key, monotonic_ms()}))
        |> load()
      else
        true -> socket
        {:error, reason} -> assign(socket, :error, message_for(reason))
      end

    {:noreply, socket}
  end

  # Approve moves the task on, so the page opens on the stage it moved to.
  def handle_event("approve_stage_output", _params, socket) do
    %{current_scope: scope, task: task} = socket.assigns

    # A page drawn before another tab approved still sends this, and the approval refuses it.
    socket =
      with %Task{stage: :custom} <- task,
           {:ok, _run} <- Pipeline.approve_stage_output(scope, custom_run(task, task.custom_stage)) do
        {:ok, moved} = Pipeline.get_task(task.id)
        send(self(), :task_changed)
        socket |> assign(:error, nil) |> pick(default_item(moved))
      else
        %Task{} -> assign(socket, :error, message_for(:already_approved))
        {:error, {:invalid_stage, _stage}} -> assign(socket, :error, message_for(:already_approved))
        {:error, reason} -> assign(socket, :error, message_for(reason))
      end

    {:noreply, load(socket)}
  end

  def handle_event("approve_fix_plan", %{"version" => version}, socket) do
    %{current_scope: scope, run: run} = socket.assigns

    socket =
      case Pipeline.approve_fix_plan(scope, run, String.to_integer(version)) do
        {:ok, _run} ->
          send(self(), :task_changed)
          assign(socket, :error, nil)

        {:error, {:fix_plan_replaced, saved_at}} ->
          assign(socket, :error, {:replaced, saved_at})

        {:error, reason} ->
          assign(socket, :error, message_for(reason))
      end

    {:noreply, load(socket)}
  end

  # Only a card this tab drew is marked, as the path comes from the page. The digest is the one the reader saw, so a
  # click from a page drawn before a revision marks the version read, which then reads revised.
  def handle_event("toggle_plan_file_reviewed", %{"path" => path, "digest" => digest, "reviewed" => reviewed}, socket) do
    %{current_scope: scope, task: task, fix_plan_reviewed: marks, fix_plan_paths: paths} = socket.assigns

    if marks && path in paths do
      {:ok, _mark} = Git.set_file_viewed(scope, task, :fix_plan, path, digest, reviewed == "true")
      {:noreply, assign_fix_plan_cards(socket)}
    else
      {:noreply, socket}
    end
  end

  # The line is read off this tab's own copy of the plan by its key, so only a line it shows can be commented on.
  def handle_event("open_document_comment", %{"doc" => "fix_plan", "key" => key}, socket) do
    %{fix_plan_lines: lines, fix_plan_offered: offered} = socket.assigns

    socket =
      case offered && Enum.find(lines, &(&1.key == key)) do
        %{} = line ->
          draft = %{
            doc: :fix_plan,
            key: line.key,
            kind: line.kind,
            label: line.label,
            text: line.text,
            occurrence: line.occurrence,
            body: nil
          }

          assign(socket, :fix_plan_draft, draft)

        _gone_or_not_offered ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("change_plan_comment", %{"body" => body}, %{assigns: %{fix_plan_draft: %{} = draft}} = socket) do
    {:noreply, assign(socket, :fix_plan_draft, %{draft | body: body})}
  end

  def handle_event("change_plan_comment", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_plan_comment", _params, socket) do
    {:noreply, assign(socket, :fix_plan_draft, nil)}
  end

  # A blank comment is refused and the box stays open on what was typed. It goes to the review agent, which writes
  # the plan, through the conversation's tray.
  def handle_event("save_plan_comment", %{"body" => body}, %{assigns: %{fix_plan_draft: %{} = draft}} = socket) do
    attrs = %{
      target: :fix_plan,
      body: body,
      element_kind: draft.kind,
      element_label: draft.label,
      element_occurrence: draft.occurrence,
      element_text: draft.text
    }

    case Pipeline.create_plan_comment(socket.assigns.current_scope, socket.assigns.run, attrs) do
      {:ok, _comment} ->
        socket = socket |> assign(:fix_plan_draft, nil) |> assign(:error, nil) |> assign_fix_plan_comments()
        {:noreply, socket}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, :fix_plan_draft, %{draft | body: body})}

      {:error, reason} ->
        socket = socket |> assign(:fix_plan_draft, nil) |> assign(:error, message_for(reason))
        {:noreply, socket}
    end
  end

  def handle_event("save_plan_comment", _params, socket), do: {:noreply, socket}

  # Read back rather than dropped from the list, since another tab may have sent it.
  def handle_event("remove_plan_comment", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.plan_comments, &(&1.id == id)) do
      %PlanComment{} = comment ->
        {:ok, _removed} = Pipeline.delete_plan_comment(socket.assigns.current_scope, comment)
        {:noreply, assign_fix_plan_comments(socket)}

      nil ->
        {:noreply, assign_fix_plan_comments(socket)}
    end
  end

  # The URL's item opens a task the stage starts showing, a child switched to included; after that the stage
  # keeps its own, so the page's patches never send it back to an item it has left.
  defp open_url_item(%{assigns: %{task: %Task{id: id}}} = socket, %{task: %Task{id: id}}), do: socket

  defp open_url_item(socket, assigns) do
    item =
      item(assigns[:url_item], assigns.task) ||
        if(assigns[:split_parent], do: :children, else: default_item(assigns.task))

    assign(socket, :item, item)
  end

  # A file the URL names opens in the diff, and stays open once the reader moves on from it.
  defp open_url_file(socket, %{url_file: file}) when is_binary(file) and file != "" do
    diff_file = if socket.assigns[:url_file] == file, do: socket.assigns.diff_file, else: file
    socket |> assign(:url_file, file) |> assign(:diff_file, diff_file)
  end

  defp open_url_file(socket, _assigns), do: socket

  # A page opens on what the task is waiting on now.
  defp default_item(%Task{stage: :custom} = task), do: custom_stage_item(task.issue, Task.current_stage(task)).key
  defp default_item(%Task{stage: :plan}), do: :plan
  defp default_item(%Task{stage: :engineer}), do: :diff
  defp default_item(%Task{}), do: :findings

  # The page puts the open item in the URL, so a reload comes back to it.
  defp pick(socket, item) do
    if item != socket.assigns.item, do: send(self(), {:review_item, item})
    assign(socket, :item, item)
  end

  defp assign_demo_and_browsers(%{assigns: %{task: task}} = socket, runs) do
    recording = Tools.get_browser_recording(task) != nil
    sessions = sessions(task, runs, recording)
    browser = picked_browser(sessions, socket.assigns.browser)

    socket
    |> assign(:beats, Pipeline.list_demo_beats(task))
    |> assign(:recorded, Task.demo_recorded?(task))
    |> assign(:recording, recording)
    |> assign(:sessions, sessions)
    |> assign(:browser, browser)
    |> assign(:url, browser && socket.assigns.item == :browser && Tools.get_browser_url(task, browser))
  end

  # Everything the open item shows is read off the rows and the disk again; what only one item needs is
  # read only while it is the one open.
  defp load(socket) do
    %{task: task, current_scope: scope} = socket.assigns
    findings = Pipeline.list_findings(task)
    passes = Pipeline.read_review(task)
    runs = role_runs(task)
    rounds = Pipeline.list_rounds(task)
    latest = List.last(rounds)
    ci = runs[:engineer] && Pipeline.get_ci_status(runs[:engineer])
    fix_plan = Pipeline.read_fix_plan(task)
    plan_state = fix_plan && FixPlan.state(fix_plan, task, findings)
    phase = phase(runs, task, passes, ci, plan_state)
    counts = counts(findings)
    selected = Enum.find(findings, List.first(findings), &(&1.key == socket.assigns.selected_key))

    socket
    |> assign(:passes, passes)
    |> assign(:fix_plan, fix_plan)
    |> assign(:plan_state, plan_state)
    |> assign_rounds(rounds, fix_plan, plan_state)
    |> assign(:plan_run, runs[:plan])
    |> assign(:plan_label, plan_label(task, runs[:plan], List.first(rounds)))
    |> assign_fix_plan(fix_plan, plan_state, findings)
    |> assign_fix_plan_comments()
    |> assign_fix_plan_cards()
    |> assign(:findings, findings)
    |> assign(:phase, phase)
    |> assign(:round, round(phase, passes, fix_plan, latest))
    |> assign(:work, work(latest, fix_plan))
    |> assign(:engineer, engineer(runs[:engineer]))
    |> assign(:sha, ci_sha(ci))
    |> assign(:counts, counts)
    |> assign(
      :agents,
      if(socket.assigns.item == :findings and phase in [:round, :planning, :fixing], do: agents(runs), else: [])
    )
    |> assign(:tally, tally(phase, counts, findings, passes))
    |> assign_branch(passes)
    |> assign_screen_comments()
    |> assign_demo_and_browsers(runs)
    |> assign_custom_stage()
    |> assign_items()
    |> assign_selected(selected, findings)
    |> assign(:commentable, task.stage in [:review, :finalize, :merged] and is_nil(task.cleaned_up_at))
    |> assign_finding_comments()
    |> assign(:comments, if(socket.assigns.item == :comments, do: Pipeline.list_comments(scope, task), else: []))
    |> watch()
    |> tray(findings, passes, phase)
  end

  # The custom stage item open, with its run beside it, and whether the stage the task is at waits on its Approve.
  defp assign_custom_stage(%{assigns: %{task: task, item: item, current_scope: scope}} = socket) do
    open =
      with "stage-" <> _number <- item,
           %{name: name} = found <- custom_stage_item(task.issue, item),
           %Run{} = run <- custom_run(task, name) do
        Map.put(found, :run, run)
      else
        _not_a_custom_stage -> nil
      end

    approvable =
      task.stage == :custom and is_nil(task.cleaned_up_at) and match?(%{user: %{}}, scope) and
        custom_stage_waiting?(task, custom_run(task, task.custom_stage))

    socket
    |> assign(:custom_item, open)
    |> assign(:beside, item in [:plan, :fix_plan] or open != nil)
    |> assign(:stage_approvable, approvable)
    |> assign(:stage_unsent, if(approvable, do: length(Pipeline.list_plan_comments(scope, task)), else: 0))
  end

  defp custom_run(%Task{runs: runs}, name), do: Enum.find(runs, &match?(%Run{role: %Role{custom_stage: ^name}}, &1))

  # Each comment opens where it was left, as the tray and the rail open the same places.
  defp open_comment(socket, %{kind: :diff, comment: comment}) do
    socket
    |> pick(:diff)
    |> assign(:diff_open, %{
      view: DiffComment.calculate_view(comment),
      comment: comment.id,
      at: System.unique_integer([:positive])
    })
    |> assign(:diff_file, comment.path)
    |> load()
  end

  # A state a retake or a cleanup took away leaves the grid open.
  defp open_comment(socket, %{kind: :screen, comment: %ScreenComment{key: key}}) do
    key = if Enum.any?(socket.assigns.screens, &(&1.key == key)), do: key
    socket |> pick(:screens) |> open_screen(key) |> load()
  end

  defp open_comment(socket, %{kind: :finding, comment: %FindingComment{finding: finding}}) do
    socket |> pick(:findings) |> assign(:selected_key, finding.key) |> assign(:filed_index, 0) |> load()
  end

  defp open_comment(socket, %{kind: :plan, comment: %PlanComment{target: :fix_plan}}) do
    item = if waiting_plan?(socket.assigns), do: :fix_plan, else: :plan
    socket |> pick(item) |> assign(:plan_round, nil) |> load()
  end

  # The Plan stage and the conversation beside it are the page's, so the page opens them.
  defp open_comment(socket, %{kind: :plan, comment: %PlanComment{target: target}}) do
    send(self(), {:open_plan, %{tab: Atom.to_string(target)}})
    socket
  end

  defp open_comment(socket, %{kind: :message, comment: %{role: role}}) do
    send(self(), {:open_plan, %{agent: Atom.to_string(role.stage)}})
    socket
  end

  # The round's plan, what changed in its rulings and whether it can be approved. Its item opens only while there is one.
  defp assign_fix_plan(socket, fix_plan, plan_state, findings) do
    %{task: task, run: run, current_scope: scope} = socket.assigns

    ruling_changes =
      if fix_plan, do: FixPlan.calculate_ruling_changes(fix_plan, task, findings), else: %{unsent: [], since_plan: []}

    # Once approved, the next round's plan is that round's, read in the Plan item like any other.
    socket =
      if socket.assigns.item == :fix_plan and (fix_plan == nil or plan_state == :approved),
        do: pick(socket, :plan),
        else: socket

    socket
    |> assign(:fix_plan, fix_plan)
    |> assign(:plan_state, plan_state)
    |> assign(:ruling_changes, ruling_changes)
    |> assign(:revising, revising(fix_plan, plan_state, run, ruling_changes))
    |> assign(:show_approve, approve?(task, plan_state, scope))
  end

  # The reader's comments on the next round's plan, numbered as the tray numbers them, under the lines they were
  # written on. A line takes one while the plan waits on approval and the review agent can take a message; they are
  # read only while the plan is the item open.
  defp assign_fix_plan_comments(socket) do
    %{fix_plan: fix_plan, plan_state: state, run: run, task: task, current_scope: scope, item: item} = socket.assigns
    open? = item == :fix_plan and match?(%FixPlan{plan: plan} when is_binary(plan), fix_plan)
    lines = if open?, do: fix_plan |> FixPlan.build_sheet() |> build_fix_plan_lines() |> Map.fetch!(:lines), else: []
    comments = if open? and match?(%{user: %{}}, scope), do: Pipeline.list_plan_comments(scope, task), else: []
    numbered = comments |> Enum.with_index(1) |> Enum.filter(&(elem(&1, 0).target == :fix_plan))
    placement = calculate_document_comments(lines, numbered)

    offered =
      open? and state != :approved and is_nil(task.cleaned_up_at) and Run.can_chat?(run) and
        match?(%{user: %{}}, scope)

    socket
    |> assign(:fix_plan_lines, lines)
    |> assign(:fix_plan_offered, offered)
    |> assign(:plan_comments, comments)
    |> assign(:fix_plan_comments, placement)
    |> assign(:fix_plan_draft, if(offered, do: socket.assigns.fix_plan_draft))
    |> report_lifted(if(open?, do: Enum.map(placement.lifted, &elem(&1, 0).id)))
  end

  # The reader's marks on the round's cards, which of their files the default branch has and which the task already
  # changed, read only while the plan is the item open. Git is asked once per set of paths and HEAD the round was sent
  # on, so a comment or an unrelated update does not ask again.
  defp assign_fix_plan_cards(socket) do
    %{fix_plan: fix_plan, item: item, task: task, current_scope: scope} = socket.assigns

    case item == :fix_plan && fix_plan && FixPlan.build_sheet(fix_plan) do
      %{} = sheet ->
        paths = sheet.files |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.sort()
        socket = assign(socket, :fix_plan_reviewed, fix_plan_marks(scope, task, sheet.round))

        if socket.assigns[:fix_plan_paths_of] == {paths, fix_plan.head},
          do: socket,
          else:
            socket
            |> assign(:fix_plan_paths_of, {paths, fix_plan.head})
            |> assign(:fix_plan_paths, paths)
            |> assign(:fix_plan_default_paths, Git.list_default_branch_paths(task.project, paths))
            |> assign(:fix_plan_diff_paths, if(is_nil(task.cleaned_up_at), do: Git.list_branch_paths(task, paths)))

      _closed ->
        socket
        |> assign(:fix_plan_reviewed, nil)
        |> assign(:fix_plan_paths_of, nil)
        |> assign(:fix_plan_paths, [])
        |> assign(:fix_plan_default_paths, nil)
        |> assign(:fix_plan_diff_paths, nil)
    end
  end

  # A card's digest starts with its round, so a mark on an earlier round's card for the same file does not stand.
  defp fix_plan_marks(scope, task, round) do
    scope
    |> Git.list_viewed_files(task, :fix_plan)
    |> Map.filter(fn {_path, digest} -> String.starts_with?(digest, "#{round}-") end)
  end

  # The conversation's tray marks the same comments changed, and hears of it only when they change.
  defp report_lifted(%{assigns: %{reported_lifted: ids}} = socket, ids), do: socket
  defp report_lifted(socket, nil), do: socket

  defp report_lifted(socket, ids) do
    send(self(), {:plan_comments_lifted, ids})
    assign(socket, :reported_lifted, ids)
  end

  # The conversation's tray shows what Send sends and whether it can; the page holds both and hands them on.
  defp tray(socket, findings, passes, phase) do
    %{stage: stage, cleaned_up_at: cleaned_up_at} = socket.assigns.task
    # While a round's plan waits on approval, Send carries only what changed since the last Send.
    plan = socket.assigns.plan_state in [:writing, :revising, :waiting, :outdated]

    # Past Review the review is over and nobody rules, so only the reader's comments go, with no Finish review.
    gate = %{
      working: phase in [:round, :planning, :fixing, :ci],
      finished: stage != :review or (passes != [] and List.last(passes).finished_at != nil),
      ci_failed: phase == :ci_failed,
      saved: passes != [],
      plan: plan,
      # A waiting plan whose rulings now leave nothing to fix and no comment is finished, not revised, by a Send.
      emptied:
        plan and stage == :review and match?(%FixPlan{comments: []}, socket.assigns.fix_plan) and
          not Enum.any?(findings, &Finding.outstanding?/1),
      undecided: if(stage == :review, do: Enum.count(findings, &Finding.undecided?/1), else: 0)
    }

    # The Fix findings went out with the Send, so they come back only if the round ends with them still outstanding.
    # A fix commit moves HEAD past the pass, and the gate then reads :round, so every working phase hides them.
    fix = if gate.working or plan or stage != :review, do: [], else: Enum.filter(findings, &Finding.outstanding?/1)

    # Comments are taken until cleanup, so a cleaned-up task, or one not yet at Review, sends nothing from it.
    tray =
      if stage in [:review, :finalize, :merged] and is_nil(cleaned_up_at),
        do: %{fix: fix, rulings: if(gate.working, do: [], else: socket.assigns.ruling_changes.unsent), gate: gate}

    send(self(), {:review_tray, tray})
    socket
  end

  # The reader's unsent screen comments mark the grid's cards and list in the screen view.
  defp assign_screen_comments(%{assigns: %{current_scope: %{user: %{}} = scope, task: task}} = socket) do
    comments = Pipeline.list_screen_comments(scope, task)

    socket
    |> assign(:screen_comments, comments)
    |> assign(:unsent_screens, Enum.frequencies_by(comments, & &1.key))
    |> assign_opened()
  end

  # Numbered as the tray numbers them, which lists finding comments first; the open finding's go under their pieces.
  defp assign_finding_comments(%{assigns: %{current_scope: %{user: %{}} = scope, task: task}} = socket) do
    comments = Pipeline.list_finding_comments(scope, task)
    %{selected: selected, finding_draft: draft, commentable: commentable} = socket.assigns
    selected_id = selected && selected.id

    placed =
      comments
      |> Enum.with_index(1)
      |> Enum.filter(fn {comment, _number} -> comment.finding_id == selected_id end)
      |> Enum.group_by(fn {comment, _number} -> {comment.piece, comment.index} end)

    # A box left open on another finding, or on a task that stopped taking comments, closes.
    draft = if commentable and match?(%{finding_id: ^selected_id}, draft), do: draft

    socket
    |> assign(:finding_comments, comments)
    |> assign(:finding_placed, placed)
    |> assign(:finding_draft, draft)
  end

  # A state a retake or a cleanup took away closes the view, and its box with it.
  defp assign_opened(%{assigns: %{screens: screens, screen_open: key}} = socket) do
    case Enum.find_index(screens, &(&1.key == key)) do
      index when is_integer(index) ->
        comments = Enum.filter(socket.assigns.screen_comments, &(&1.key == key))
        assign(socket, :opened, %{screen: Enum.at(screens, index), position: index + 1, comments: comments})

      nil ->
        socket |> assign(:opened, nil) |> assign(:screen_draft, nil)
    end
  end

  defp open_screen(socket, key), do: socket |> assign(:screen_open, key) |> assign(:screen_draft, nil)

  # A step never runs past either end, and leaves a box being written in alone.
  defp step_screen(%{assigns: %{opened: %{position: position}, screens: screens, screen_draft: nil}} = socket, step) do
    case Enum.at(screens, position - 1 + step) do
      %{key: key} when position + step >= 1 -> socket |> open_screen(key) |> assign_opened()
      _end -> socket
    end
  end

  defp step_screen(socket, _step), do: socket

  # The branch's commits label each finding's and screen's commit, count the Diff item and date the demo.
  # The commits each round read are what tell the engineer's apart from each fix round's.
  defp assign_branch(%{assigns: %{task: task}} = socket, passes) do
    history = Git.load_branch_history(task, for(%{head: head} <- passes, is_binary(head), do: head))
    demo = Pipeline.read_demo(task)

    socket
    |> assign(:demo, demo)
    |> assign(:history, history)
    |> assign(:labels, Map.new(history.commits, &{&1.sha, &1.label}))
    |> assign(:screens, Pipeline.list_screens(task))
    |> assign(:stale, stale(demo, history))
  end

  # The page holds the subscription a frame arrives on, so it is told which browser is being watched.
  defp watch(socket) do
    watched = if socket.assigns.item == :browser, do: socket.assigns.browser
    send(self(), {:watch_browser, watched})
    socket
  end

  defp assign_selected(socket, nil, _findings) do
    socket
    |> assign(:selected, nil)
    |> assign(:selected_key, nil)
    |> assign(:position, 0)
    |> assign(:neighbours, %{previous: nil, next: nil})
    |> assign_code(nil)
    |> assign(:filed, [])
    |> assign(:names, %{})
    |> assign(:suppressor, nil)
  end

  defp assign_selected(socket, %Finding{} = selected, findings) do
    index = Enum.find_index(findings, &(&1.key == selected.key))
    open? = socket.assigns.item == :findings

    socket
    |> assign(:selected, selected)
    |> assign(:selected_key, selected.key)
    |> assign(:position, index + 1)
    |> assign(:neighbours, %{
      previous: if(index > 0, do: Enum.at(findings, index - 1).key),
      next: if(index < length(findings) - 1, do: Enum.at(findings, index + 1).key)
    })
    |> assign(:filed, if(open?, do: filed(socket, selected), else: []))
    |> assign(:names, if(open?, do: names(socket, selected), else: %{}))
    |> assign(:suppressor, if(open?, do: suppressor(selected)))
    |> assign_code(if(open?, do: selected))
  end

  defp assign_items(socket) do
    %{phase: phase, counts: counts, sessions: sessions} = socket.assigns

    findings = %{
      key: :findings,
      label: "Findings",
      icon: "pi-list-checks",
      picked_icon: "pi-list-checks-fill",
      state: findings_state(phase, counts, socket.assigns),
      # Nothing is ruled while the engineer has the round, so what it waits on shows instead of the count to rule.
      badge: if(phase not in [:round, :fixing, :blocked, :stalled, :ci] and counts.undecided > 0, do: counts.undecided),
      dot: if(phase in [:round, :fixing, :ci], do: :running),
      mark:
        cond do
          phase == :finished -> :done
          phase == :blocked -> :waiting
          phase == :ci_failed -> :failed
          phase == :stalled -> if(socket.assigns.engineer.error, do: :failed, else: :stopped)
          true -> nil
        end
    }

    diff = %{
      key: :diff,
      label: "Diff",
      icon: "pi-git-diff",
      picked_icon: "pi-git-diff-fill",
      state: diff_state(socket.assigns.history) <> conflicts_state(socket.assigns.task),
      badge: nil,
      dot: nil,
      mark: if(socket.assigns.task.base_conflicts != [], do: :failed)
    }

    screens = %{
      key: :screens,
      label: "Screens",
      icon: "pi-images",
      picked_icon: "pi-images-fill",
      state: screens_state(socket.assigns.screens),
      badge: nil,
      dot: nil,
      mark: nil
    }

    demo = %{
      key: :demo,
      label: "Demo",
      icon: "pi-video-camera",
      picked_icon: "pi-video-camera-fill",
      state: demo_label(socket.assigns),
      badge: nil,
      dot: if(socket.assigns.recording, do: :recording),
      mark: demo_mark(socket.assigns)
    }

    browser = %{
      key: :browser,
      label: "Browser",
      icon: "pi-browsers",
      picked_icon: "pi-browsers-fill",
      state: browser_state(sessions),
      badge: nil,
      dot: browser_dot(sessions),
      mark: nil
    }

    items =
      page_items(socket.assigns) ++ shown(socket.assigns, [findings, diff, screens, demo, browser])

    assign(socket, :items, Enum.reject(items, &(&1 in [nil, false])))
  end

  defp browser_dot(sessions) do
    cond do
      Enum.any?(sessions, &(&1.state == :recording)) -> :recording
      Enum.any?(sessions, &(&1.state == :driving)) -> :running
      true -> nil
    end
  end

  # Each part of the work shows once there is something of it to read: the diff and the browser once the task is
  # built, the rest once it is reviewed.
  defp shown(%{task: task, passes: passes}, [findings, diff, screens, demo, browser]) do
    reviewed? = task.stage in [:review, :finalize, :merged] or passes != []
    # A custom stage can run before the engineer has built anything, or after.
    built? =
      task.stage not in [:plan, :custom] or
        (task.stage == :custom and Enum.any?(task.runs, &match?(%Run{role: %Role{stage: :engineer}}, &1)))

    [reviewed? && findings, built? && diff, reviewed? && screens, reviewed? && demo, built? && browser]
  end

  # The rounds the Plan item reads: each one approved, and the next one's while it waits. A round's plan reads as
  # it was approved; the first round's is the whole combined plan.
  defp assign_rounds(socket, rounds, fix_plan, plan_state) do
    next? = fix_plan != nil and plan_state != :approved

    options =
      Enum.map(rounds, &{to_string(&1.number), round_label(&1)}) ++
        if(next?, do: [{"next", "Round #{length(rounds) + 1} · waiting on approval"}], else: [])

    latest = if rounds == [], do: "1", else: to_string(List.last(rounds).number)
    asked = if socket.assigns.item == :fix_plan, do: "next", else: socket.assigns.plan_round || latest
    pick = if Enum.any?(options, &(elem(&1, 0) == asked)), do: asked, else: latest

    socket
    |> assign(:round_options, options)
    |> assign(:round_pick, pick)
    |> assign(:shown_round, Enum.find(rounds, &(to_string(&1.number) == pick)))
  end

  defp round_label(%Round{number: 1}), do: "Round 1 · the plan"
  defp round_label(%Round{number: number}), do: "Round #{number}"

  defp waiting_plan?(%{fix_plan: %FixPlan{}, plan_state: state}), do: state != :approved
  defp waiting_plan?(_assigns), do: false

  # The whole task's items before the review's: the issue, the plan with its conversation, each custom stage it has
  # reached on the side of Plan its sequence puts it, a split's children and every comment on the task.
  defp page_items(assigns) do
    sequence = Issue.calculate_stages(assigns.task.issue)
    {before_plan, after_plan} = if :plan in sequence, do: Enum.split_while(sequence, &(&1 != :plan)), else: {[], sequence}

    [
      %{
        key: :issue,
        label: "Issue",
        icon: "pi-ticket",
        picked_icon: "pi-ticket-fill",
        state: assigns.task.issue.identifier,
        badge: nil,
        dot: nil,
        mark: nil
      }
      | custom_items(assigns.task, before_plan)
    ] ++
      [
        Map.merge(
          %{
            key: :plan,
            label: "Plan",
            icon: "pi-clipboard-text",
            picked_icon: "pi-clipboard-text-fill",
            state: assigns.plan_label,
            # Its conversation is beside it, so the questions waiting there are counted on it.
            badge: if(assigns.questions > 0 and assigns.task.stage != :custom, do: assigns.questions),
            dot: if(assigns.task.stage == :plan and Run.running?(assigns.plan_run), do: :running),
            mark: nil
          },
          fix_plan_item(assigns) || %{}
        )
        | custom_items(assigns.task, after_plan)
      ] ++
      [
        assigns.split &&
          %{
            key: :children,
            label: "Children",
            icon: "pi-tree-structure",
            picked_icon: "pi-tree-structure-fill",
            state: "The split's children",
            badge: nil,
            dot: nil,
            mark: nil
          },
        %{
          key: :comments,
          label: "Comments",
          icon: "pi-chats",
          picked_icon: "pi-chats-fill",
          state: "Every comment on the task",
          badge: nil,
          dot: nil,
          mark: nil
        }
      ]
  end

  # A custom stage shows once it has a run, saying what it waits on: an answer, its file, or the reader's Approve.
  defp custom_items(%Task{} = task, stages) do
    saved = task |> Pipeline.read_stage_outputs() |> Enum.map(& &1.name)

    for {:custom, name} = stage <- stages, %Run{} = run <- [custom_run(task, name)] do
      questions = Enum.count(run.questions, &(&1.status == :pending))

      {state, dot, mark} =
        case {Run.state(run), name in saved} do
          {state, _saved?} when state in [:running, :waiting] -> {"running", :running, nil}
          {:blocked, _saved?} -> {"needs an answer", nil, :waiting}
          {:failed, _saved?} -> {"failed", nil, :failed}
          {:done, _saved?} -> {"approved", nil, :done}
          {_stopped, true} -> {"waiting on you", nil, :waiting}
          {_stopped, false} -> {"no file saved", nil, :waiting}
        end

      %{
        key: custom_stage_item(task.issue, stage).key,
        label: name,
        icon: "pi-puzzle-piece",
        picked_icon: "pi-puzzle-piece-fill",
        state: state,
        badge: if(questions > 0, do: questions),
        dot: dot,
        mark: mark
      }
    end
  end

  # The next round's plan, while there is one, is what the Plan item says it is doing.
  defp fix_plan_item(%{fix_plan: nil}), do: nil
  defp fix_plan_item(%{plan_state: :approved}), do: nil

  defp fix_plan_item(%{plan_state: plan_state, run: run}) do
    {state, dot, mark} =
      case {Run.running?(run), plan_state} do
        {true, :writing} -> {"Writing the plan", :running, nil}
        {true, _revising} -> {"Revising", :running, nil}
        {false, :waiting} -> {"Waiting on your approval", nil, :waiting}
        {false, :outdated} -> {"Out of date", nil, :waiting}
        {false, :writing} -> {"No plan", nil, :stopped}
        {false, :revising} -> {"Revision stopped", nil, :stopped}
      end

    %{state: state, dot: dot, mark: mark}
  end

  # What a plan being revised is revised on: the rulings changed since it was saved, the comments it does not cover,
  # or else a message, which revises it too.
  defp revising(%FixPlan{plan: plan} = fix_plan, plan_state, run, ruling_changes) when is_binary(plan) do
    revising? = plan_state == :revising or (Run.running?(run) and plan_state in [:waiting, :outdated])

    if revising? do
      rulings = length(ruling_changes.since_plan)
      comments = for %{number: number} <- fix_plan.comments, number > fix_plan.covered_comments, do: number

      case Enum.reject([rulings > 0 && plural(rulings, "changed ruling"), numbers(comments)], &(&1 in [false, nil])) do
        [] -> "your message"
        said -> Enum.join(said, " and ")
      end
    end
  end

  defp revising(_fix_plan, _plan_state, _run, _ruling_changes), do: nil

  defp numbers([]), do: nil
  defp numbers([one]), do: "comment #{one}"
  defp numbers(many), do: "comments #{Enum.join(Enum.drop(many, -1), ", ")} and #{List.last(many)}"

  # What the lead was sent to plan on, while it writes the first plan.
  defp asked(%FixPlan{findings: findings, comments: comments}) do
    findings = if findings != [], do: "the #{plural(length(findings), "finding")} ruled Fix"

    [findings, numbers(Enum.map(comments, & &1.number))]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" and ")
  end

  # What goes before the change at `index` of `count`, so the banner reads as one sentence.
  defp separator(0, _count), do: ""
  defp separator(index, count), do: if(index == count - 1, do: " and ", else: ", ")

  defp ruling(:fix), do: "Fix"
  defp ruling(:skip), do: "Don't fix"

  # Approve starts the engineer, so it is offered only on the latest plan while it waits and nothing works on the
  # task, the checks included, as the approval itself requires.
  defp approve?(%Task{} = task, :waiting, scope) do
    task.stage in [:review, :finalize, :merged] and is_nil(task.cleaned_up_at) and not Task.running?(task) and
      match?(%{user: %{}}, scope)
  end

  defp approve?(%Task{}, _plan_state, _scope), do: false

  # Where the round is, read off its runs: the engineer building it and its CI, the agents checking it, and the
  # review agent's plan for the next. Until that plan is approved, nothing changes the branch.
  defp phase(runs, %Task{} = task, passes, ci, plan_state) do
    checking? = Enum.any?([:qa, :review, :review_lead], &Run.running?(runs[&1]))

    cond do
      match?(%{state: :running}, ci) -> :ci
      task.stage == :engineer and match?(%{state: :failed, failures: failures} when failures >= 3, ci) -> :ci_failed
      task.stage == :engineer -> engineer_phase(Run.state(runs[:engineer]))
      Run.running?(runs[:review_lead]) and plan_state in [:writing, :revising, :waiting, :outdated] -> :planning
      plan_state in [:waiting, :outdated] -> plan_state
      checking? -> :round
      passes != [] and List.last(passes).finished_at != nil -> :finished
      true -> :ruling
    end
  end

  # At Engineer the round is the engineer's: at work, in line or about to start, or waiting on an answer, or on a
  # retry once it failed or stopped.
  defp engineer_phase(:blocked), do: :blocked
  defp engineer_phase(state) when state in [:failed, :stopped], do: :stalled
  defp engineer_phase(_running_waiting_or_starting), do: :fixing

  # What the round at Engineer is: the fix plan approved for it, an Update merging the default branch in, which
  # only those two start past round 1, or the task's own first plan.
  defp work(%Round{plan: plan}, %FixPlan{plan: plan, approved_at: %DateTime{}} = fix_plan),
    do: {:fix, length(fix_plan.covered_keys), fix_plan.covered_comments}

  defp work(%Round{number: number}, _fix_plan) when number > 1, do: :update
  defp work(_first_or_none, _fix_plan), do: :build

  # What the engineer waits on: the first line of the question it asked, or the error it failed on.
  defp engineer(%Run{} = run) do
    question = Enum.find(run.questions, &(&1.status == :pending))
    %{question: question && first_line(question.prompt), error: run.error && first_line(run.error)}
  end

  defp engineer(nil), do: %{question: nil, error: nil}

  defp first_line(text), do: text |> String.trim() |> String.split("\n", parts: 2) |> hd()

  # Each role's run on the task, by its stage; a custom stage's role has none.
  defp role_runs(%Task{runs: runs}) do
    for %Run{role: %Role{stage: stage}} = run <- runs, is_atom(stage) and stage != nil, into: %{}, do: {stage, run}
  end

  defp plan_label(%Task{stage: :plan}, plan_run, _first),
    do: if(Run.running?(plan_run), do: "Plan is writing", else: "Not approved yet")

  # A task whose workflow turned every Plan step off has nothing to approve, and one a custom stage runs before
  # Plan has not reached it yet. Work its owner started without a tech lead's approval still waits on one.
  defp plan_label(%Task{issue: issue} = task, plan_run, first) do
    cond do
      :plan not in Issue.calculate_stages(issue) -> "Off for this workflow"
      task.stage == :custom and plan_run == nil -> "Not started yet"
      match?(%Round{approved_at: nil}, first) -> "Started without approval"
      true -> "Approved"
    end
  end

  # A fix plan is numbered for the review it answers, and the engineer's work for the round it builds.
  defp round(phase, _passes, fix_plan, _latest) when phase in [:planning, :waiting, :outdated], do: fix_plan.round

  defp round(phase, _passes, _fix_plan, %Round{number: number})
       when phase in [:fixing, :blocked, :stalled, :ci, :ci_failed], do: number

  defp round(:round, passes, _fix_plan, _latest), do: length(passes) + 1
  defp round(_phase, passes, _fix_plan, _latest), do: max(length(passes), 1)

  defp counts(findings) do
    %{
      total: length(findings),
      undecided: Enum.count(findings, &Finding.undecided?/1),
      # An unruled finding goes to the round on its recommendation, but is counted as still to rule.
      fix: Enum.count(findings, &(Finding.outstanding?(&1) and not Finding.undecided?(&1))),
      fixed: Enum.count(findings, &(&1.status == :fixed)),
      dismissed: Enum.count(findings, &(Finding.state(&1) in [:dismissed, :suppressed]))
    }
  end

  defp tally(:round, counts, _findings, passes),
    do: "#{counts.total} so far · rule once round #{length(passes) + 1} finishes"

  defp tally(phase, counts, _findings, _passes) when phase in [:fixing, :ci],
    do: said([{counts.fix, "fixing"}, {counts.fixed, "fixed"}, {counts.dismissed, "not fixing"}])

  defp tally(_phase, %{total: 0}, _findings, _passes), do: "No findings"

  defp tally(_phase, counts, _findings, _passes) do
    said([
      {counts.undecided, "to rule"},
      {counts.fix, "to fix"},
      {counts.fixed, "fixed"},
      {counts.dismissed, "not fixing"}
    ])
  end

  defp said(parts) do
    parts
    |> Enum.reject(fn {count, _word} -> count == 0 end)
    |> Enum.map_join(" · ", fn {count, word} -> "#{count} #{word}" end)
  end

  defp findings_state(:round, _counts, assigns), do: "Round #{assigns.round} running"
  defp findings_state(:fixing, _counts, %{work: :update} = assigns), do: "Round #{assigns.round} · Update running"
  defp findings_state(:fixing, _counts, assigns), do: "Round #{assigns.round} running"
  defp findings_state(:blocked, _counts, assigns), do: "Round #{assigns.round} · Engineer waiting on an answer"

  defp findings_state(:stalled, _counts, %{engineer: %{error: nil}} = assigns),
    do: "Round #{assigns.round} · Engineer stopped"

  defp findings_state(:stalled, _counts, assigns), do: "Round #{assigns.round} · Engineer failed"
  defp findings_state(:ci, _counts, %{sha: sha}), do: "CI running" <> if(sha, do: " on #{sha}", else: "")
  defp findings_state(:ci_failed, _counts, %{sha: sha}), do: "CI failed" <> if(sha, do: " on #{sha}", else: "")
  defp findings_state(:finished, _counts, _assigns), do: "Nothing left to rule"
  defp findings_state(:planning, _counts, assigns), do: "Fix round #{assigns.round} · writing the fix plan"

  defp findings_state(phase, counts, assigns) when phase in [:waiting, :outdated],
    do: findings_state(:ruling, counts, assigns)

  defp findings_state(:ruling, counts, _assigns) do
    case said([{counts.undecided, "to rule"}, {counts.fix, "to fix"}]) do
      "" -> "Nothing to rule"
      state -> state
    end
  end

  defp diff_state(%{commits: []}), do: "No commits yet"

  defp diff_state(history),
    do: "#{plural(length(history.commits), "commit")} · +#{history.additions} -#{history.deletions}"

  # The branch would conflict with the default branch, which the header's Update merges in.
  defp conflicts_state(%Task{base_conflicts: []}), do: ""

  defp conflicts_state(%Task{base_conflicts: paths, project: project}),
    do: " · conflicts with #{project.default_branch} in #{plural(length(paths), "file")}"

  defp screens_state([]), do: "No screens yet"

  defp screens_state(screens) do
    latest = Enum.max_by(screens, & &1.taken_at, DateTime)
    on = if latest.commit, do: " · on #{String.slice(latest.commit, 0, 7)}", else: ""
    "#{plural(length(screens), "screen")}#{on}"
  end

  # A demo the task's workflow turned off reads as off, whatever was recorded before.
  defp demo_label(assigns) do
    if Issue.skips_step?(assigns.task.issue, :demo), do: "Off for this workflow", else: demo_state(assigns)
  end

  defp demo_mark(assigns) do
    cond do
      Issue.skips_step?(assigns.task.issue, :demo) -> :off
      assigns.stale && not assigns.recording -> :stale
      true -> nil
    end
  end

  defp demo_state(%{recording: true, beats: [_one]}), do: "Recording · 1 beat said so far"
  defp demo_state(%{recording: true, beats: beats}), do: "Recording · #{length(beats)} beats said so far"

  defp demo_state(%{recorded: true, stale: %{} = stale}), do: stale_text(stale)

  defp demo_state(%{recorded: true, demo: %{commit: commit}}) when is_binary(commit),
    do: "Recorded on #{String.slice(commit, 0, 7)}"

  defp demo_state(%{recorded: true}), do: "Recorded"
  defp demo_state(_none), do: "None recorded"

  defp browser_state([]), do: "No browsers open"

  defp browser_state(sessions) do
    recording = Enum.count(sessions, &(&1.state == :recording))
    driving = Enum.count(sessions, &(&1.state == :driving))
    count = if length(sessions) == 1, do: "1 browser", else: "#{length(sessions)} browsers"

    cond do
      recording > 0 -> "#{recording} recording"
      driving > 0 -> "#{count} · #{driving} driving"
      true -> "#{count} · idle"
    end
  end

  # A tab is driving while the run works and Rail holds it, and the demo recorder's is recording while filmed.
  defp sessions(%Task{} = task, runs, recording) do
    running = Enum.any?(Map.values(runs), &Run.running?/1)

    for session <- Tools.list_browser_sessions(task) do
      state =
        cond do
          recording and session.name == "demo" -> :recording
          running and Tools.get_browser_session(task, session.name) != nil -> :driving
          true -> :idle
        end

      %{name: session.name, account: session.account, state: state}
    end
  end

  defp picked_browser(sessions, picked) do
    if Enum.any?(sessions, &(&1.name == picked)), do: picked, else: sessions |> List.first() |> then(&(&1 && &1.name))
  end

  # The agents checking the round, each a run Rail started, with what each is for.
  defp agents(runs) do
    for {stage, work} <- [
          engineer: "Builds the round",
          qa: "Tests the running app and shoots each screen state",
          review: "Reads the diff",
          demo: "Records the demo",
          review_lead: "Turns the reports into findings and the next plan"
        ],
        %Run{} = run <- [runs[stage]],
        Run.running?(run),
        do: %{name: run.role.name, work: work, running: true}
  end

  # How many of the branch's commits came after the one the demo was recorded on, counted when the tab draws.
  # A commit the branch no longer has, after a rebase, is behind by a count nobody can give.
  defp stale(%{commit: commit}, %{commits: [_latest | _earlier] = commits}) when is_binary(commit) do
    case Enum.find_index(commits, &(&1.sha == commit)) do
      0 -> nil
      behind when is_integer(behind) -> %{commit: commit, behind: behind}
      nil -> %{commit: commit, behind: nil}
    end
  end

  defp stale(_demo, _history), do: nil

  defp stale_text(%{commit: commit, behind: nil}),
    do: "Recorded on #{String.slice(commit, 0, 7)}, which the branch no longer has; may be out of date"

  defp stale_text(%{commit: commit, behind: behind}),
    do: "Recorded on #{String.slice(commit, 0, 7)}, #{plural(behind, "commit")} ago; may be out of date"

  defp plural(1, word), do: "1 #{word}"
  defp plural(count, word), do: "#{count} #{word}s"

  defp ci_sha(%{os_process: %{head_sha: sha}}) when is_binary(sha), do: String.slice(sha, 0, 7)
  defp ci_sha(_no_ci), do: nil

  # A finding's code is read once, and again only once the branch moves, as DiffView keeps its diff.
  defp assign_code(socket, nil), do: socket |> assign(:code, @no_code) |> assign(:head, nil)

  defp assign_code(socket, %Finding{key: key} = finding) do
    %{task: task, current_scope: scope, code_cache: cache} = socket.assigns
    fingerprint = if Task.worktree_present?(task), do: Git.branch_fingerprint(task.worktree_path)
    by_key = if cache.fingerprint == fingerprint, do: cache.by_key, else: %{}
    code = Map.get_lazy(by_key, key, fn -> load_code(scope, task, finding) end)

    socket
    |> assign(:code, code)
    |> assign(:head, fingerprint[:head_sha])
    |> assign(:code_cache, %{fingerprint: fingerprint, by_key: Map.put(by_key, key, code)})
  end

  # The Where first, then each code place, in one read. A place on the Where's lines shares its code, and a
  # finding with one place keeps its plain row, so only its Where's code is read.
  defp load_code(scope, task, %Finding{places: places} = finding) do
    where = if is_binary(finding.file), do: {finding.file, finding.line, finding.end_line}
    where_place = where && Enum.find_index(places, &same_lines?(&1, where))

    coded =
      for {%FindingPlace{file: file} = place, n} <- Enum.with_index(places),
          length(places) > 1 and is_binary(file) and n != where_place,
          do: {n, {file, place.line, place.end_line}}

    ranges = List.wrap(where) ++ Enum.map(coded, &elem(&1, 1))
    excerpts = if ranges == [], do: [], else: Git.load_diff_hunks(scope, task, ranges)
    {where_excerpt, place_excerpts} = if where, do: {hd(excerpts), tl(excerpts)}, else: {nil, excerpts}

    %{
      where: where_excerpt,
      where_place: where_place,
      places: coded |> Enum.map(&elem(&1, 0)) |> Enum.zip(place_excerpts) |> Map.new()
    }
  end

  defp same_lines?(%FindingPlace{file: file} = place, {where_file, line, end_line}) when is_binary(file) do
    String.trim_leading(file, "./") == String.trim_leading(where_file, "./") and place.line == line and
      last_line(place.line, place.end_line) == last_line(line, end_line)
  end

  defp same_lines?(%FindingPlace{}, _where), do: false

  defp last_line(line, end_line) when is_integer(end_line) and end_line > line, do: end_line
  defp last_line(line, _end_line), do: line

  # Read off the row alone: a text file's opening was read into the finding when it was attached.
  defp filed(socket, %Finding{key: key, evidence: evidence}) do
    task = socket.assigns.task

    for {piece, index} <- Enum.with_index(evidence), piece.kind != :code do
      url = if is_binary(piece.path), do: ~p"/tasks/#{task.id}/findings/#{key}/evidence/#{index}"
      %{index: index, evidence: piece, kind: kind(piece), url: url}
    end
  end

  defp kind(%FindingEvidence{text: text}) when is_binary(text), do: :inline

  defp kind(%FindingEvidence{path: path}) do
    cond do
      FindingEvidence.picture?(path) -> :screenshot
      String.downcase(Path.extname(path)) == ".pdf" -> :pdf
      true -> :file
    end
  end

  defp names(socket, %Finding{notes: notes}) do
    case for(%{by_id: id} <- notes, is_binary(id), uniq: true, do: id) do
      [] ->
        %{}

      ids ->
        socket.assigns.current_scope |> Users.list_users_by_ids(ids) |> Map.new(&{&1.id, &1.name || &1.login})
    end
  end

  defp suppressor(%Finding{suppressed_by_id: rule_id} = finding) when is_binary(rule_id) do
    if Finding.suppressed?(finding) do
      {:ok, rules} = Learnings.list_learnings(ids: [rule_id])
      List.first(rules)
    end
  end

  defp suppressor(%Finding{}), do: nil

  # The next one down that still needs a call, or else the first from the top.
  defp next_undecided(findings, finding) do
    {above, [_ruled | below]} = Enum.split_while(findings, &(&1.key != finding.key))
    Enum.find(below ++ above, &Finding.undecided?/1)
  end

  # The second click of a double click lands on the finding just moved to, which nobody has read yet.
  defp double_click?({key, at}, key), do: monotonic_ms() - at < @double_click_ms
  defp double_click?(_advanced_to, _key), do: false

  # A custom stage's item opens once its stage has a run to show.
  defp item("stage-" <> _number = item, %Task{} = task) do
    case custom_stage_item(task.issue, item) do
      %{key: key, name: name} -> if custom_run(task, name), do: key
      nil -> nil
    end
  end

  defp item(item, %Task{}), do: item(item)

  defp item("issue"), do: :issue
  defp item("plan"), do: :plan
  defp item("conversation"), do: :plan
  defp item("children"), do: :children
  defp item("comments"), do: :comments
  defp item("fix_plan"), do: :fix_plan
  defp item("diff"), do: :diff
  defp item("screens"), do: :screens
  defp item("demo"), do: :demo
  defp item("browser"), do: :browser
  defp item("findings"), do: :findings
  defp item(_unnamed), do: nil

  defp decision("fix"), do: :fix
  defp decision("skip"), do: :skip

  defp message_for(:already_approved), do: "That stage was already approved."
  defp message_for(:no_output), do: "Nothing is saved to approve yet."
  defp message_for(:stage_running), do: "Something is still running on this task."
  defp message_for({:step_off, :demo}), do: "The demo is off for this workflow."
  defp message_for(:no_stage_run), do: "Review has no run to ask yet."
  defp message_for(:chat_unavailable), do: "The Review lead has no conversation to ask yet."
  defp message_for({:invalid_stage, stage}), do: "This task is at #{Task.stage_label(stage)}, not Review."
  defp message_for(:review_finished), do: "The review is finished, so its rulings are settled."
  defp message_for(:cleaned_up), do: "This task is cleaned up, so it takes no more comments."
  defp message_for(:not_found), do: "That screen is gone: a retake or a cleanup removed it."
  defp message_for({:unanswered_questions, 1}), do: "Answer or dismiss the open question first. Nothing started."

  defp message_for({:unanswered_questions, count}),
    do: "Answer or dismiss the #{count} open questions first. Nothing started."

  defp message_for({:unsent_comments, count}), do: unsent(count)
  defp message_for(:no_fix_plan), do: "There is no fix plan waiting on approval."
  defp message_for({:fix_plan_not_waiting, :outdated}), do: "A ruling changed since that plan was saved. Nothing started."
  defp message_for({:fix_plan_not_waiting, :approved}), do: "That fix plan is already approved."
  defp message_for({:fix_plan_not_waiting, _writing}), do: "The lead is revising that fix plan. Nothing started."

  defp unsent(1), do: "Send or remove your unsent comment first."
  defp unsent(count), do: "Send or remove your #{count} unsent comments first."
end
