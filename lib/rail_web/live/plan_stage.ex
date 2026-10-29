defmodule RailWeb.Live.PlanStage do
  @moduledoc """
  The Plan step: the ticket, the design options and the plan, each a tab that switches in the browser, and the one
  Approve in the header. A child of a split shows only its approved part. A step the task's workflow turned off
  reads as off, and with Product off the issue stands as the ticket.

  Everything here is read off scratch and the runs whenever the page reloads it, so a save shows
  the moment it lands. What waits on the human opens when the step opens, and only a click changes it after.

  Once a design is picked the reader can comment on its elements while Plan can take a message, and on any line of
  the ticket or the plan once it is saved, through the + beside it. The mode and the open comment box are this tab's
  alone; the comments are rows, and the conversation sends them.
  """
  use RailWeb, :live_component

  import RailWeb.Utils.BuildDocumentBlocks
  import RailWeb.Utils.CalculateDocumentComments

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
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
      |> assign_new(:line_draft, fn -> nil end)
      |> assign_new(:reported_changed, fn -> nil end)
      |> assign_new(:selected_key, fn -> nil end)
      |> load()
      |> assign_reviewed()
      |> assign_default_paths()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="plan-stage" data-qa="plan-stage" class="contents">
      <p
        :if={@error}
        id="plan-error"
        data-qa="plan_error"
        class="px-6 pt-3 text-xs text-red-600 dark:text-red-500"
      >
        {@error}
      </p>

      <.child_plan_pane
        :if={@child_of}
        child_of={@child_of}
        plan={@plan}
        sheet={@sheet}
        criteria={@criteria}
        default_paths={@default_paths}
        project={@task.project}
        target={@myself}
      />

      <div :if={!@child_of} id="plan-pane" class="@container h-full flex flex-col min-h-0">
        <div
          id={"plan-tabs-#{@task.id}"}
          role="tablist"
          aria-label="Plan"
          class="shrink-0 flex items-center gap-6 px-6 @5xl:px-8 border-b border-slate-200 dark:border-slate-700 overflow-x-auto"
        >
          <button
            :for={tab <- @tabs}
            type="button"
            role="tab"
            id={"plan-tab-#{tab.id}"}
            data-qa="plan_tab"
            aria-controls={"plan-section-#{tab.id}"}
            aria-selected={to_string(tab.id == @open_tab.tab)}
            phx-mounted={JS.ignore_attributes(["aria-selected"])}
            phx-click={show_tab(@task, tab.id)}
            class={[
              "shrink-0 inline-flex items-center gap-2 h-10 px-1 border-b-2 border-transparent text-[13.5px] font-semibold text-slate-500 dark:text-slate-400 not-aria-selected:hover:text-slate-900 dark:not-aria-selected:hover:text-slate-100 not-aria-selected:hover:border-slate-300 dark:not-aria-selected:hover:border-slate-500 aria-selected:border-indigo-500 dark:aria-selected:border-indigo-400 cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 rounded-t",
              tab.mark != :off && "aria-selected:text-slate-900 dark:aria-selected:text-slate-100"
            ]}
          >
            {tab.label}
            <span
              :if={tab.mark == :off}
              id={"plan-tab-#{tab.id}-off"}
              data-qa="plan_tab_off"
              title="Off for this workflow"
              class="inline-flex text-slate-400 dark:text-slate-500"
            >
              <.icon name="pi-minus-circle" class="size-4" />
              <span class="sr-only">, off for this workflow</span>
            </span>
            <span
              :if={tab.mark == :pick}
              id={"plan-tab-#{tab.id}-waiting"}
              data-qa="plan_tab_waiting"
              class="grid place-items-center size-[1.1rem] rounded-full bg-amber-100 dark:bg-amber-950 text-amber-900 dark:text-amber-200"
            >
              <.icon name="pi-hand-palm-fill" class="size-2.5" />
              <span class="sr-only">, waiting on your pick</span>
            </span>
            <span
              :if={tab.mark == :working}
              id={"plan-tab-#{tab.id}-working"}
              data-qa="plan_tab_working"
              class="block size-3 shrink-0 rounded-full border-2 border-slate-300 dark:border-slate-600 border-t-blue-500 motion-safe:animate-spin"
            >
              <span class="sr-only">, being written</span>
            </span>
          </button>
        </div>

        <div id={"plan-panels-#{@task.id}"} class="flex-1 min-h-0">
          <.plan_section id="ticket" open={@open_tab.tab}>
            <.ticket_pane
              issue={if :product in @skipped, do: @task.issue}
              ticket={@ticket}
              lines={@ticket_lines}
              running={@running}
              pick_up={@pick_up}
              placed={@ticket_comments.placed}
              changed={@ticket_comments.lifted}
              draft={@line_draft}
              offered={@ticket_offered}
              target={@myself}
            />
          </.plan_section>

          <.plan_section id="design" open={@open_tab.tab}>
            <.step_off
              :if={:design in @skipped}
              id="plan-design-off"
              icon="pi-palette"
              text="This workflow turned Design off, so its tasks have no design options."
            />
            <.design_pane
              :if={:design not in @skipped}
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
          </.plan_section>

          <.plan_section id="plan" open={@open_tab.tab}>
            <.step_off
              :if={:architect in @skipped}
              id="plan-plan-off"
              icon="pi-list-checks"
              text={"This workflow turned Architect off, so there is no implementation plan. Engineer builds from #{if :product in @skipped, do: "the issue", else: "the ticket"}."}
            />
            <.plan_pane
              :if={:architect not in @skipped}
              plan={@plan}
              sheet={@sheet}
              banner={@banner}
              approved={@approved}
              running={@running}
              pending_text={@pending_text}
              criteria={@criteria}
              lines={@plan_lines}
              reviewed={@reviewed}
              default_paths={@default_paths}
              project={@task.project}
              placed={@plan_comments.placed}
              changed={@plan_comments.lifted}
              draft={@line_draft}
              offered={@plan_offered}
              target={@myself}
            />
          </.plan_section>
        </div>
      </div>
    </div>
    """
  end

  @impl true
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
        %{} = draft -> socket |> assign(:draft, draft) |> assign(:line_draft, nil)
        _off_or_malformed -> socket
      end

    {:noreply, socket}
  end

  # The line is read off this tab's own copy of the document by its key, so only a line it shows can be commented on.
  def handle_event("open_document_comment", %{"doc" => doc, "key" => key}, socket) when doc in ["ticket", "plan"] do
    %{ticket_line_list: ticket_lines, plan_lines: plan_lines} = socket.assigns

    {lines, offered} =
      if doc == "ticket",
        do: {ticket_lines, socket.assigns.ticket_offered},
        else: {plan_lines, socket.assigns.plan_offered}

    socket =
      case offered && Enum.find(lines, &(&1.key == key)) do
        %{} = line ->
          draft = %{
            doc: String.to_existing_atom(doc),
            key: line.key,
            kind: line.kind,
            label: line.label,
            text: line.text,
            occurrence: line.occurrence,
            body: nil
          }

          socket |> assign(:line_draft, draft) |> assign(:draft, nil)

        _gone_or_not_offered ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("change_plan_comment", %{"body" => body}, %{assigns: %{line_draft: %{} = draft}} = socket) do
    {:noreply, assign(socket, :line_draft, %{draft | body: body})}
  end

  def handle_event("change_plan_comment", %{"body" => body}, %{assigns: %{draft: %{} = draft}} = socket) do
    {:noreply, assign(socket, :draft, %{draft | body: body})}
  end

  def handle_event("change_plan_comment", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_plan_comment", _params, socket) do
    socket = socket |> assign(:draft, nil) |> assign(:line_draft, nil)
    {:noreply, socket}
  end

  # A blank comment is refused and the box stays open on what was typed.
  def handle_event("save_plan_comment", %{"body" => body}, %{assigns: %{line_draft: %{} = draft}} = socket) do
    attrs = %{
      target: draft.doc,
      body: body,
      element_kind: draft.kind,
      element_label: draft.label,
      element_occurrence: draft.occurrence,
      element_text: draft.text
    }

    case Pipeline.create_plan_comment(socket.assigns.current_scope, socket.assigns.run, attrs) do
      {:ok, _comment} ->
        socket = socket |> assign(:line_draft, nil) |> assign(:error, nil) |> assign_comments()
        {:noreply, socket}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, :line_draft, %{draft | body: body})}

      {:error, reason} ->
        socket |> assign(:line_draft, nil) |> then(&respond({:error, reason}, &1))
    end
  end

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

  def handle_event("remove_plan_comment", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.comments, &(&1.id == id)) do
      %PlanComment{} = comment ->
        {:ok, _removed} = Pipeline.delete_plan_comment(socket.assigns.current_scope, comment)
        {:noreply, assign_comments(socket)}

      # Another tab removed or sent it already.
      nil ->
        {:noreply, assign_comments(socket)}
    end
  end

  # Only a card this page drew is marked, as the path comes from the page. The digest is the one the reader saw, so a
  # click from a page drawn before a revision marks the version read, which then reads revised.
  def handle_event("toggle_plan_file_reviewed", %{"path" => path, "digest" => digest, "reviewed" => reviewed}, socket) do
    %{current_scope: scope, task: task, sheet: sheet} = socket.assigns

    if sheet && Enum.any?(sheet.cards, &(&1.path == path)) do
      {:ok, _mark} = Git.set_file_viewed(scope, task, :plan, path, digest, reviewed == "true")
      {:noreply, assign(socket, :reviewed, Git.list_viewed_files(scope, task, :plan))}
    else
      {:noreply, socket}
    end
  end

  # --- Panes ---

  attr :issue, :any, default: nil, doc: "the issue, which stands as the ticket when the workflow turned Product off"
  attr :ticket, :any, required: true
  attr :lines, :map, required: true, doc: "the ticket's title, priority and estimate lines, and its description's"
  attr :running, :boolean, required: true
  attr :pick_up, :string, required: true
  attr :placed, :map, required: true
  attr :changed, :list, required: true
  attr :draft, :map, default: nil
  attr :offered, :boolean, required: true
  attr :target, :any, required: true

  defp ticket_pane(%{issue: %Issue{}} = assigns) do
    ~H"""
    <div id="plan-ticket-from-issue" data-qa="plan_ticket_from_issue" class="max-w-3xl select-text">
      <p class="flex items-start gap-1.5 text-xs text-slate-500 dark:text-slate-400">
        <.icon name="pi-info" class="mt-0.5 size-3.5 shrink-0" />
        Product is off for this workflow, so the issue's description is the ticket.
      </p>
      <h2
        id="plan-ticket-issue-title"
        class="mt-3 text-xl font-bold text-slate-900 dark:text-slate-100 wrap-break-word"
      >
        {@issue.title}
      </h2>
      <.markdown
        :if={@issue.description not in [nil, ""]}
        content={@issue.description}
        assets_base={~p"/issues/#{@issue.id}/assets"}
        class="mt-3 text-[15px] leading-relaxed wrap-break-word"
      />
    </div>
    """
  end

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
      <.changed_comments id="ticket-changed-comments" comments={@changed} target={@target} />

      <.commentable_line
        line={@lines.title}
        doc={:ticket}
        placed={@placed}
        draft={@draft}
        offered={@offered}
        target={@target}
      >
        <h2
          id="plan-ticket-title"
          class="text-xl font-bold text-slate-900 dark:text-slate-100 wrap-break-word"
        >
          {@ticket.title}
        </h2>
      </.commentable_line>

      <.commentable_line
        layout={:values}
        doc={:ticket}
        placed={@placed}
        draft={@draft}
        offered={@offered}
        target={@target}
        class="mt-1 mb-3"
      >
        <:value line={@lines.priority}>
          <.priority_icon :if={@ticket.priority} priority={@ticket.priority} />
          <span id="plan-ticket-priority">{@lines.priority.text}</span>
        </:value>
        <:value line={@lines.estimate}>
          <.icon name="pi-triangle" class="size-3.5 text-slate-500 dark:text-slate-400" />
          <span id="plan-ticket-estimate">{@lines.estimate.text}</span>
        </:value>
      </.commentable_line>

      <div id="plan-ticket-description">
        <.commentable_line
          :for={line <- @lines.description}
          line={line}
          layout={layout(line)}
          doc={:ticket}
          placed={@placed}
          draft={@draft}
          offered={@offered}
          target={@target}
        />
      </div>
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
  attr :criteria, :list, required: true, doc: "the ticket's acceptance criteria, for the plan's criteria table"
  attr :lines, :list, required: true, doc: "the plan's lines, read off its sheet or, without one, off its markdown"
  attr :reviewed, :map, default: nil, doc: "the cards the reader marked reviewed, by path, with the digest each had"
  attr :default_paths, :any, required: true
  attr :project, :any, required: true
  attr :placed, :map, required: true
  attr :changed, :list, required: true
  attr :draft, :map, default: nil
  attr :offered, :boolean, required: true
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
        criteria={@criteria}
        default_paths={@default_paths}
        project={@project}
        target={@target}
        reviewed={@reviewed}
        placed={@placed}
        changed={@changed}
        draft={@draft}
        offered={@offered}
      />
      <div :if={@sheet == nil}>
        <.changed_comments id="plan-changed-comments" comments={@changed} target={@target} />
        <.commentable_line
          :for={line <- @lines}
          line={line}
          layout={layout(line)}
          doc={:plan}
          placed={@placed}
          draft={@draft}
          offered={@offered}
          target={@target}
        />
      </div>
      <p
        :if={@approved}
        class="mt-6 text-[13px] text-slate-500 dark:text-slate-400"
      >
        Engineer, Code Reviewer, QA and Demo Presenter work from this plan exactly as approved.
      </p>
    </div>
    """
  end

  attr :child_of, :map, required: true
  attr :plan, :any, required: true
  attr :sheet, :any, required: true
  attr :criteria, :list, required: true
  attr :default_paths, :any, required: true
  attr :project, :any, required: true
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
          criteria={@criteria}
          part={@child_of.position}
          default_paths={@default_paths}
          project={@project}
          target={@target}
        />
        <.markdown :if={@sheet == nil} content={@plan.content} class="text-[15px] leading-relaxed" />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :text, :string, required: true

  # A part the task's workflow turned off, which nobody writes and approval does not wait on.
  defp step_off(assigns) do
    ~H"""
    <div id={@id} data-qa={@id} class="flex flex-col items-center text-center max-w-md mx-auto py-14">
      <div class="relative flex items-center justify-center size-14 rounded-2xl bg-slate-100 dark:bg-slate-800 text-slate-400 ring-1 ring-slate-200 dark:ring-slate-700">
        <.icon name={@icon} class="size-7" />
        <span class="absolute -top-1.5 -right-1.5 grid place-items-center size-5 rounded-full bg-white dark:bg-slate-900">
          <.icon name="pi-minus-circle" class="size-5" />
        </span>
      </div>
      <h2 class="mt-5 text-base font-semibold text-slate-900 dark:text-slate-100">
        Off for this workflow
      </h2>
      <p class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">{@text}</p>
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

  attr :id, :string, required: true
  attr :open, :string, required: true, doc: "the tab the page opened on"
  slot :inner_block, required: true

  # Every part is on the page and only the open one shows, so a tab switches without asking the server.
  defp plan_section(assigns) do
    ~H"""
    <section
      id={"plan-section-#{@id}"}
      role="tabpanel"
      aria-labelledby={"plan-tab-#{@id}"}
      tabindex="0"
      data-qa="plan_section"
      phx-mounted={JS.ignore_attributes(["class"])}
      class={[
        "h-full min-w-0 overflow-y-auto px-6 @5xl:px-8 py-5 @5xl:py-6 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-blue-500",
        @id != @open && "hidden"
      ]}
    >
      {render_slot(@inner_block)}
    </section>
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
    # The combined plan is the first round's; a later round carries the ticket as its plan changed it.
    rounds = Pipeline.list_rounds(task)
    round = List.first(rounds)
    latest = List.last(rounds)
    ticket = latest && latest.ticket && Map.put(Map.from_struct(latest.ticket), :saved_at, latest.plan_saved_at)
    design = Pipeline.read_design(task)
    plan = if round && round.plan, do: %{content: round.plan, saved_at: round.plan_saved_at, design: round.design}
    approved = plan != nil and round.approved_at != nil
    running = Run.running?(run)
    can_chat = Run.can_chat?(run)
    # Once the work started, a comment asks the review agent for a change to the plan, the design or the ticket.
    amending = approved and task.stage in [:review, :finalize] and Run.can_chat?(socket.assigns[:chat_run])
    picked = design && Enum.find(design.options, &(&1.key == design.picked))
    selected_key = selected_key(design, socket.assigns.selected_key)
    ticket_lines = ticket_lines(ticket)
    sheet = sheet(plan, ticket_lines)
    skipped = task.issue.skipped_steps
    tabs = tabs(ticket, design, picked, plan, running, skipped)

    socket
    |> assign(:skipped, skipped)
    |> assign(:ticket, ticket)
    |> assign_ticket_lines(ticket_lines)
    |> assign(:design, design)
    |> assign(:plan, plan)
    |> assign(:sheet, sheet)
    |> assign(:plan_lines, plan_lines(plan, sheet))
    |> assign(:approved, approved)
    |> assign(:running, running)
    |> assign(:can_pick, task.stage == :plan and can_chat)
    |> assign_offered(if(:product in skipped, do: nil, else: ticket), plan, (can_chat and not approved) or amending)
    |> assign(:selected_key, selected_key)
    |> assign(:option, shown_option(design, selected_key))
    |> assign(:tabs, tabs)
    |> assign_open_tab(task, tabs, plan)
    |> assign(:banner, banner(plan, picked, running))
    |> assign(:pick_up, pick_up(run))
    |> assign(:pending_text, pending_text(running, pick_up(run)))
    |> assign(:comment_reason, comment_reason(design, run, approved and not amending))
    |> stop_commenting_unless_allowed()
    |> close_line_draft_unless_offered()
    |> assign_comments()
  end

  # Git is asked once per set of paths the sheet shows, so a comment or an unrelated update does not ask again.
  defp assign_default_paths(socket) do
    %{task: task, sheet: sheet} = socket.assigns
    paths = Enum.sort(Enum.uniq(card_paths(sheet)))

    if socket.assigns[:default_paths_of] == paths do
      socket
    else
      socket
      |> assign(:default_paths_of, paths)
      |> assign(:default_paths, Git.list_default_branch_paths(task.project, paths))
    end
  end

  defp card_paths(%{cards: cards}), do: Enum.map(cards, & &1.path)
  defp card_paths(nil), do: []

  # Numbered in round order, so a card on a line carries the number the tray gives it.
  defp assign_comments(socket) do
    %{current_scope: scope, task: task, design: design} = socket.assigns
    comments = Pipeline.list_plan_comments(scope, task)
    numbered = Enum.with_index(comments, 1)
    picked = design && design.picked

    markers =
      for {comment, number} <- numbered,
          comment.target == :design and comment.option_key == picked,
          do: %{id: comment.id, number: number, selector: comment.selector}

    ticket_lines = socket.assigns.ticket_line_list
    ticket = calculate_document_comments(ticket_lines, Enum.filter(numbered, &(elem(&1, 0).target == :ticket)))
    plan = calculate_document_comments(socket.assigns.plan_lines, Enum.filter(numbered, &(elem(&1, 0).target == :plan)))

    socket
    |> assign(:comments, comments)
    |> assign(:markers, markers)
    |> assign(:ticket_comments, ticket)
    |> assign(:plan_comments, plan)
    |> report_changed(Enum.map(ticket.lifted ++ plan.lifted, &elem(&1, 0).id))
  end

  # The conversation's tray marks the same comments changed, and hears of it only when they change.
  defp report_changed(%{assigns: %{reported_changed: ids}} = socket, ids), do: socket

  defp report_changed(socket, ids) do
    send(self(), {:plan_comments_lifted, ids})
    assign(socket, :reported_changed, ids)
  end

  # A line takes a comment once its document is saved, while Plan can take a message and nobody has approved yet.
  defp assign_offered(socket, ticket, plan, open) do
    socket
    |> assign(:ticket_offered, ticket != nil and open)
    |> assign(:plan_offered, plan != nil and open)
  end

  defp close_line_draft_unless_offered(%{assigns: %{line_draft: %{doc: :ticket}, ticket_offered: false}} = socket),
    do: assign(socket, :line_draft, nil)

  defp close_line_draft_unless_offered(%{assigns: %{line_draft: %{doc: :plan}, plan_offered: false}} = socket),
    do: assign(socket, :line_draft, nil)

  defp close_line_draft_unless_offered(socket), do: socket

  # The title, the priority and the estimate are lines of the ticket as much as its description's are.
  defp assign_ticket_lines(socket, nil),
    do: socket |> assign(:ticket_lines, nil) |> assign(:ticket_line_list, []) |> assign(:criteria, [])

  defp assign_ticket_lines(socket, lines) do
    socket
    |> assign(:ticket_lines, lines)
    |> assign(:ticket_line_list, [lines.title, lines.priority, lines.estimate | lines.description])
    |> assign(:criteria, criteria_lines(lines))
  end

  defp ticket_lines(nil), do: nil

  defp ticket_lines(ticket) do
    priority = (ticket.priority && Issue.priority_label(ticket.priority)) || "No priority"

    estimate =
      case ticket.estimate do
        1 -> "1 Point"
        points when is_integer(points) -> "#{points} Points"
        nil -> "No estimate"
      end

    %{
      title: ticket_line(:title, ticket.title, "Title"),
      priority: ticket_line(:priority, priority, "Priority"),
      estimate: ticket_line(:estimate, estimate, "Estimate"),
      description: build_document_blocks(ticket.description || "")
    }
  end

  defp ticket_line(kind, text, label) do
    %{key: "#{kind}-#{:erlang.phash2({text, 1})}", kind: kind, text: text, occurrence: 1, label: label, depth: 0}
  end

  # A row for each of the ticket's criteria, so one the plan leaves out takes a comment too.
  defp sheet(nil, _ticket_lines), do: nil

  defp sheet(plan, ticket_lines),
    do: build_plan_sheet(plan.content, ticket_lines |> criteria_lines() |> Enum.map(& &1.number))

  # Offered on the task's own plan alone, not on the part a child was approved with.
  defp assign_reviewed(%{assigns: %{sheet: nil}} = socket), do: assign(socket, :reviewed, nil)
  defp assign_reviewed(%{assigns: %{child_of: %{}}} = socket), do: assign(socket, :reviewed, nil)

  defp assign_reviewed(%{assigns: %{current_scope: scope, task: task}} = socket),
    do: assign(socket, :reviewed, Git.list_viewed_files(scope, task, :plan))

  defp plan_lines(nil, _sheet), do: []
  defp plan_lines(_plan, %{lines: lines}), do: lines
  defp plan_lines(plan, nil), do: build_document_blocks(plan.content)

  defp layout(%{kind: :code}), do: :code
  defp layout(%{kind: :table_row}), do: :table_row
  defp layout(_line), do: :text

  # Comments go to Plan through its conversation, and once the work started to the review agent, which only a
  # task under review has.
  defp comment_reason(_design, _run, true),
    do: "The plan is approved, so the design takes comments again once the round is under review."

  # Before a pick there is nothing to comment on, and the pick comes first.
  defp comment_reason(%{picked: picked}, %Run{} = run, false) when is_binary(picked) do
    if Run.can_chat?(run), do: nil, else: "Cannot chat with #{run.role.name} yet"
  end

  defp comment_reason(_no_pick, _run, false), do: "Pick a design to comment on it."

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

  # Under the element when there is room below it, above it when there is room above, and otherwise, for an element
  # covering most of the frame, inside it near the element's top, so the frame never clips the box.
  defp box_style(draft) do
    left = "left: clamp(8px, #{percent(draft.x, 1920)}%, calc(100% - 448px)); width: min(440px, calc(100% - 16px));"

    cond do
      draft.y + draft.height <= 1080 * 0.6 -> "#{left} top: calc(#{percent(draft.y + draft.height, 1080)}% + 10px);"
      draft.y >= 1080 * 0.4 -> "#{left} bottom: calc(#{percent(1080 - draft.y, 1080)}% + 10px);"
      true -> "#{left} top: calc(#{percent(draft.y, 1080)}% + 10px);"
    end
  end

  # Clamped, so an element scrolled partly out of the frame cannot push the box out of it.
  defp percent(value, whole), do: (value / whole * 100) |> max(0.0) |> min(100.0) |> Float.round(3)

  # A tab is its label, marked only where something waits: the pick on the reader, or a part Plan is writing. A
  # part the workflow turned off is marked off.
  defp tabs(ticket, design, picked, plan, running, skipped) do
    revising = plan != nil and picked != nil and (plan.design == nil or plan.design.key != picked.key)

    [
      %{id: "ticket", label: "Ticket", mark: if(ticket == nil and running, do: :working)},
      %{
        id: "design",
        label: "Design",
        mark: if(:design in skipped, do: :off, else: design_mark(design, picked, running))
      },
      %{
        id: "plan",
        label: "Plan",
        mark: if(:architect in skipped, do: :off, else: if(revising and running, do: :working))
      }
    ]
  end

  defp design_mark(design, picked, running) do
    options = if design, do: design.options, else: []

    cond do
      picked != nil -> nil
      running -> :working
      length(options) == 3 -> :pick
      true -> nil
    end
  end

  # Picked once for the task the page shows and never from the server again, so a save cannot move the reader.
  # A rejoin picks again, but the browser keeps the tab it shows. The page names one when a comment opens it.
  defp assign_open_tab(%{assigns: %{open_tab: %{task_id: id}}} = socket, %Task{id: id}, _tabs, _plan), do: socket

  defp assign_open_tab(socket, task, tabs, plan) do
    named = socket.assigns[:tab]

    tab =
      cond do
        Enum.any?(tabs, &(&1.id == named)) -> named
        Enum.any?(tabs, &(&1.mark == :pick)) -> "design"
        plan != nil -> "plan"
        true -> "ticket"
      end

    assign(socket, :open_tab, %{task_id: task.id, tab: tab})
  end

  # Done in the browser, which keeps it through every patch the server sends after.
  defp show_tab(task, id) do
    [to: "#plan-panels-#{task.id} > [role='tabpanel']:not(#plan-section-#{id})"]
    |> JS.hide()
    |> JS.show(to: "#plan-section-#{id}", display: "block")
    |> JS.set_attribute({"aria-selected", "false"}, to: "#plan-tabs-#{task.id} > [role='tab']:not(#plan-tab-#{id})")
    |> JS.set_attribute({"aria-selected", "true"}, to: "#plan-tab-#{id}")
  end

  # The ticket's own acceptance criteria, as its lines name them, for the plan's criteria table to fill its rows from.
  defp criteria_lines(nil), do: []
  defp criteria_lines(%{description: lines}), do: criteria_lines(lines)

  defp criteria_lines(lines) do
    for %{label: "Criterion " <> number} = line <- lines,
        {number, ""} <- [Integer.parse(number)],
        do: %{number: number, html: line.html}
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

  defp respond({:ok, _run}, socket) do
    send(self(), :task_changed)
    {:noreply, assign(socket, :error, nil)}
  end

  # A refusal usually means the task moved under the page, so the page reads it again.
  defp respond({:error, reason}, socket) do
    send(self(), :task_changed)
    {:noreply, assign(socket, :error, message_for(reason))}
  end

  defp message_for({:invalid_stage, stage}), do: "This task is at #{Task.stage_label(stage)}, not Plan."
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
