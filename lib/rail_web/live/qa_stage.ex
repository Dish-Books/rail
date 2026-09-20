defmodule RailWeb.Live.QaStage do
  @moduledoc """
  What QA found driving the application, read one finding at a time.

  The same master and detail the review panel uses, because the human doing this
  is the human who just did that one, but what a finding holds is different: QA
  never saw the code, so there is no diff here. There is the check it came out
  of, the steps that reproduce it, what should have happened against what did,
  and the screenshots it took while it was there.

  QA's verdict on the whole change is the first row of the list rather than a
  banner over it, because it is one more thing to read and not a frame around the
  rest: it says whether this worked, and opening it says why. It is advice, and it
  moves nothing - what the human decides finding by finding is what sends the
  change back or on, exactly as it is in review. A verdict that says `fail` next
  to findings a person has read and dismissed is a change that ships.

  The middle shows one thing at a time and the sidebar is what picks it: the
  verdict, a finding, a checklist row with the pictures taken for it, or one of
  those pictures full size. While the pass is running and nothing has been picked,
  it is the browser.

  Neither button appears while anything is unruled. Sending then would drop a
  finding from the round with nobody having said to, and going on to demo would
  read a silence as a dismissal.

  What this change broke sorts above what it merely stands next to. Both are
  worth reporting and only one of them is usually this branch's to fix.

  While the pass is running there are no findings to read yet, so what is shown
  instead is what it is doing: the checklist it wrote before it opened anything,
  going green a row at a time, beside the browser it is driving. A pass that
  stalls stalls somewhere a person can see, and one that stops half way says which
  rows it never reached.
  """
  use RailWeb, :live_component

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaCheck
  alias Rail.Pipeline.Schemas.QaChecklist
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.QaReport
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:selected_key, fn -> nil end)
      |> assign_new(:focus, fn -> nil end)

    {:ok, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="qa-stage" data-qa="qa-stage" class="contents">
      <.task_layout task={@task} run={@run} title={@task.issue.title} flush>
        <:tabs>{render_slot(@tabs)}</:tabs>

        <:actions>
          {render_slot(@actions)}

          <button
            :if={@approvable and @reported and @undecided == [] and @outstanding != []}
            type="button"
            id="send-qa-findings-to-engineer"
            data-qa="send_qa_findings_to_engineer"
            phx-click="send_qa_findings_to_engineer"
            phx-target={@myself}
            class="px-4 py-2 rounded-lg text-sm font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs"
          >
            Send {length(@outstanding)} back to engineer
          </button>

          <button
            :if={@approvable and @reported and @undecided == [] and @outstanding == []}
            type="button"
            id="send-to-demo"
            data-qa="send_to_demo"
            phx-click="send_to_demo"
            phx-target={@myself}
            class="px-4 py-2 rounded-lg text-sm font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs"
          >
            Send to demo
          </button>
        </:actions>

        <:alerts :if={@error}>
          <p id="qa-error" data-qa="qa_error" class="text-xs text-red-600 dark:text-red-500">
            {@error}
          </p>
        </:alerts>

        <div id="qa-stage-body" class="h-full flex flex-col min-h-0">
          <div class="flex-1 min-h-0 flex flex-col lg:flex-row">
            <.qa_sidebar
              report={@report}
              summary_open={@pane == :summary}
              findings={@findings}
              selected={@selected}
              checklist={@checklist}
              check={@check}
              current={@current}
              shots={@shots}
              running={@running}
              target={@myself}
            />

            <div class="flex-1 min-w-0 flex flex-col min-h-0">
              <.shot_viewer :if={@pane == :shot} task={@task} shot={@shot} target={@myself} />

              <.report_detail :if={@pane == :summary} report={@report} />

              <.check_detail
                :if={@pane == :check}
                task={@task}
                check={@check}
                shots={shots_for(@shots, @check)}
                target={@myself}
              />

              <.browser_viewer
                :if={@pane == :browser}
                task={@task}
                checklist={@checklist}
                current={@current}
                frame={@frame}
                driving={@driving}
                shots={@shots}
                target={@myself}
              />

              <.finding_detail
                :if={@pane == :finding}
                task={@task}
                finding={@selected}
                position={@position}
                count={length(@findings)}
                decidable={@approvable and not @running}
                neighbours={@neighbours}
                target={@myself}
              />

              <.qa_pending :if={@pane == :pending} reported={@reported} report={@report} />
            </div>
          </div>
        </div>

        <:sidebar>{render_slot(@sidebar)}</:sidebar>
      </.task_layout>
    </div>
    """
  end

  @impl true
  def handle_event("select_finding", %{"key" => key}, socket) do
    socket = socket |> assign(:selected_key, key) |> focus(nil)

    {:noreply, socket}
  end

  def handle_event("select_summary", _params, socket), do: {:noreply, focus(socket, :summary)}

  def handle_event("select_check", %{"key" => key}, socket), do: {:noreply, focus(socket, {:check, key})}

  # A picture takes over the middle rather than opening somewhere else, so what
  # it is of stays next to the list it was taken for.
  def handle_event("select_shot", %{"file" => file}, socket), do: {:noreply, focus(socket, {:shot, file})}

  # Closing a picture that belongs to a row goes back to the row rather than all
  # the way out, because that is where it was opened from.
  def handle_event("close_focus", params, socket), do: {:noreply, focus(socket, back(params["check"]))}

  def handle_event("decide", %{"key" => key, "decision" => decision}, socket) do
    finding = Enum.find(socket.assigns.findings, &(&1.key == key))

    socket =
      case Pipeline.decide_qa_finding(finding, decision(decision)) do
        {:ok, _decided} -> socket |> assign(:error, nil) |> load()
        {:error, reason} -> assign(socket, :error, message_for(reason))
      end

    {:noreply, socket}
  end

  def handle_event("send_qa_findings_to_engineer", _params, socket) do
    case Pipeline.send_qa_findings_to_engineer(socket.assigns.run) do
      {:ok, _run} ->
        send(self(), :task_changed)
        {:noreply, assign(socket, :error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, message_for(reason))}
    end
  end

  def handle_event("send_to_demo", _params, socket) do
    case Pipeline.send_to_demo(socket.assigns.run) do
      {:ok, _run} ->
        send(self(), :task_changed)
        {:noreply, assign(socket, :error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, message_for(reason))}
    end
  end

  attr :report, :any, required: true
  attr :open, :boolean, required: true
  attr :target, :any, required: true

  # What QA thought of the change as a whole, at the top of the list rather than
  # over it. Coloured, because the one thing a reader wants at a glance is
  # whether this worked, and clamped, because the rest of it is one click away
  # and the findings underneath are what they came for.
  defp summary_item(assigns) do
    ~H"""
    <button
      type="button"
      id="qa-verdict"
      data-qa="qa_verdict"
      data-verdict={@report.verdict}
      phx-click="select_summary"
      phx-target={@target}
      aria-current={to_string(@open)}
      class={[
        "shrink-0 w-full px-4 py-3 border-b text-left cursor-pointer",
        verdict_tone(@report.verdict),
        @open && "ring-1 ring-inset ring-blue-400 dark:ring-blue-600"
      ]}
    >
      <span class="flex items-center gap-2.5">
        <span class={["size-2 shrink-0 rounded-full", verdict_dot(@report.verdict)]} />
        <span data-qa="qa_verdict_label" class="text-sm font-bold">
          {verdict_label(@report.verdict)}
        </span>
      </span>

      <span
        :if={@report.summary}
        class="mt-1.5 block text-[12.5px] leading-snug line-clamp-2 opacity-90"
      >
        {@report.summary}
      </span>
    </button>
    """
  end

  attr :report, :any, required: true

  # The verdict at length: what QA made of the change, and what it never got to.
  defp report_detail(assigns) do
    ~H"""
    <div id="qa-report-detail" data-qa="qa_report_detail" class="flex-1 min-w-0 min-h-0 flex flex-col">
      <div class={[
        "shrink-0 flex items-center gap-3 px-7 py-4 border-b",
        verdict_tone(@report.verdict)
      ]}>
        <span class={["size-2.5 shrink-0 rounded-full", verdict_dot(@report.verdict)]} />
        <h2 class="text-base font-bold">{verdict_label(@report.verdict)}</h2>
      </div>

      <div class="flex-1 min-h-0 overflow-y-auto px-7 py-6">
        <div class="max-w-4xl space-y-5">
          <.markdown :if={@report.summary} content={@report.summary} class="text-[13.5px]" />

          <.section :if={@report.not_checked} title="What it could not check" qa="qa_not_checked">
            <.markdown content={@report.not_checked} class="text-[13px]" />
          </.section>
        </div>
      </div>
    </div>
    """
  end

  attr :target, :any, required: true
  attr :check, :string, default: nil

  # Every pane the sidebar opens closes the same way, back to whatever the panel
  # would have shown on its own.
  defp close_pane(assigns) do
    ~H"""
    <button
      type="button"
      id="qa-close-pane"
      data-qa="qa_close_pane"
      phx-click="close_focus"
      phx-target={@target}
      phx-value-check={@check}
      class="ml-auto shrink-0 px-3 py-1.5 rounded-lg border border-slate-300 dark:border-slate-600 text-xs font-semibold hover:bg-white/40 dark:hover:bg-slate-800 cursor-pointer"
    >
      Close
    </button>
    """
  end

  attr :report, :any, required: true
  attr :summary_open, :boolean, required: true
  attr :findings, :list, required: true
  attr :selected, :any, required: true
  attr :checklist, :any, required: true
  attr :check, :any, required: true
  attr :current, :any, required: true
  attr :shots, :list, required: true
  attr :running, :boolean, required: true
  attr :target, :any, required: true

  # One column, because they answer the same question from three ends: the
  # verdict is what the pass made of the change, the checklist is what it looked
  # at and the findings are what it found. A reader who has read a finding wants
  # the row it came out of, and a reader with no findings still wants to know
  # what was checked.
  defp qa_sidebar(assigns) do
    ~H"""
    <div
      id="qa-sidebar"
      data-qa="qa_sidebar"
      class="w-full lg:w-[300px] shrink-0 flex flex-col min-h-0 overflow-y-auto overflow-x-hidden border-b lg:border-b-0 lg:border-r border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/30"
    >
      <.summary_item
        :if={@report && not @running}
        report={@report}
        open={@summary_open}
        target={@target}
      />

      <.finding_list :if={@findings != []} findings={@findings} selected={@selected} target={@target} />

      <.checklist_panel
        checklist={@checklist}
        check={@check}
        current={@current}
        shots={@shots}
        target={@target}
      />
    </div>
    """
  end

  attr :findings, :list, required: true
  attr :selected, :any, required: true
  attr :target, :any, required: true

  defp finding_list(assigns) do
    ~H"""
    <div
      id="qa-finding-list"
      data-qa="qa_finding_list"
      class="shrink-0 flex flex-col border-b border-slate-200 dark:border-slate-700"
    >
      <div class="flex items-baseline gap-2 px-4 py-3 border-b border-slate-200 dark:border-slate-700">
        <span class="text-sm font-bold text-slate-900 dark:text-slate-100">Findings</span>
        <span class="text-xs text-slate-500 dark:text-slate-400">{length(@findings)}</span>
      </div>

      <div class="p-2 space-y-1">
        <button
          :for={finding <- @findings}
          type="button"
          id={"qa-finding-#{finding.key}"}
          data-qa="qa_finding"
          data-state={QaFinding.state(finding)}
          phx-click="select_finding"
          phx-target={@target}
          phx-value-key={finding.key}
          aria-current={to_string(@selected.key == finding.key)}
          class={[
            "w-full flex gap-2.5 px-3 py-2.5 rounded-lg text-left cursor-pointer",
            @selected.key == finding.key &&
              "bg-blue-50 dark:bg-blue-950/40 ring-1 ring-blue-300 dark:ring-blue-800",
            @selected.key != finding.key && "hover:bg-slate-100 dark:hover:bg-slate-800/60",
            QaFinding.state(finding) == :dismissed && "opacity-60"
          ]}
        >
          <span class={["mt-1.5 size-1.5 shrink-0 rounded-full", severity_dot(finding)]} />

          <span class="min-w-0 flex-1">
            <span class={[
              "block text-[13px] leading-snug",
              @selected.key == finding.key && "font-semibold text-slate-900 dark:text-slate-100",
              @selected.key != finding.key && "text-slate-700 dark:text-slate-300",
              QaFinding.state(finding) == :dismissed && "line-through"
            ]}>
              {finding.title}
            </span>
            <span class="block truncate text-[10px] text-slate-500 dark:text-slate-400">
              {list_subtitle(finding)}
            </span>
          </span>
        </button>
      </div>
    </div>
    """
  end

  attr :task, :any, required: true
  attr :finding, :any, required: true
  attr :position, :integer, required: true
  attr :count, :integer, required: true
  attr :decidable, :boolean, required: true
  attr :neighbours, :map, required: true
  attr :target, :any, required: true

  defp finding_detail(assigns) do
    ~H"""
    <div
      id="qa-finding-detail"
      data-qa="qa_finding_detail"
      class="flex-1 min-w-0 min-h-0 flex flex-col"
    >
      <div class="shrink-0 flex items-start gap-4 px-7 py-4 border-b border-slate-200 dark:border-slate-700">
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2.5">
            <span class={[
              "rounded px-2 py-0.5 text-[10px] font-extrabold uppercase tracking-wider",
              severity_chip(@finding)
            ]}>
              {QaFinding.severity_label(@finding.severity)}
            </span>
            <span data-qa="qa_finding_position" class="text-xs text-slate-500 dark:text-slate-400">
              {@position} of {@count}
            </span>
            <span
              :if={not QaFinding.regression?(@finding)}
              data-qa="qa_finding_pre_existing"
              class="rounded px-2 py-0.5 text-[10px] font-bold uppercase tracking-wider bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"
            >
              Not this change
            </span>
            <span
              :if={@finding.decision == nil and @finding.status != :fixed}
              data-qa="qa_finding_undecided"
              class="text-xs font-semibold text-blue-600 dark:text-blue-400"
            >
              Needs your call
            </span>
            <span
              :if={@finding.decision == :skip}
              data-qa="qa_finding_dismissed"
              class="text-xs font-semibold text-slate-500 dark:text-slate-400"
            >
              Dismissed
            </span>
            <span
              :if={@finding.status == :fixed}
              data-qa="qa_finding_fixed"
              class="text-xs font-semibold text-emerald-600 dark:text-emerald-500"
            >
              Fixed
            </span>
            <span
              :if={@finding.status == :not_fixed}
              data-qa="qa_finding_not_fixed"
              class="text-xs font-semibold text-amber-600 dark:text-amber-500"
            >
              Still not fixed
            </span>
          </div>

          <h2 class="mt-2 text-lg font-bold text-slate-900 dark:text-slate-100">{@finding.title}</h2>

          <p
            :if={@finding.screen}
            data-qa="qa_finding_screen"
            class="mt-1.5 font-mono text-[11.5px] text-slate-500 dark:text-slate-400"
          >
            {@finding.screen}
          </p>
        </div>

        <!-- A fixed finding has nothing left to rule on, so the choice, the remedy
        and the advice all go: what is left is the record that it was dealt with. -->
        <div :if={@decidable and @finding.status != :fixed} class="shrink-0 flex gap-2">
          <button
            :for={{decision, label} <- [fix: "Fix", skip: "Don't fix"]}
            type="button"
            id={"decide-#{decision}-#{@finding.key}"}
            data-qa={"decide_#{decision}"}
            phx-click="decide"
            phx-target={@target}
            phx-value-key={@finding.key}
            phx-value-decision={decision}
            aria-pressed={to_string(@finding.decision == decision)}
            class={[
              "px-3.5 py-1.5 rounded-lg text-xs font-semibold cursor-pointer",
              @finding.decision == decision && "bg-blue-600 dark:bg-blue-500 text-white",
              @finding.decision != decision &&
                "border border-slate-300 dark:border-slate-600 text-slate-600 dark:text-slate-400 hover:bg-slate-50 dark:hover:bg-slate-800"
            ]}
          >
            {label}
          </button>
        </div>
      </div>

      <div class="flex-1 min-h-0 overflow-y-auto px-7 py-6">
        <div class="max-w-4xl space-y-5">
          <div
            :if={@finding.criterion}
            data-qa="qa_finding_criterion"
            class="rounded-r-lg border border-l-2 border-slate-200 border-l-blue-500 dark:border-slate-700 dark:border-l-blue-500 bg-blue-50/50 dark:bg-blue-950/20 px-4 py-3.5"
          >
            <p class="text-[11px] font-extrabold uppercase tracking-wider text-blue-700 dark:text-blue-400">
              Fails acceptance criterion
            </p>
            <.markdown content={@finding.criterion} class="mt-2 text-[13px]" />
          </div>

          <p data-qa="qa_finding_check" class="text-xs text-slate-500 dark:text-slate-400">
            Found by: {@finding.check}
          </p>

          <.markdown :if={@finding.detail} content={@finding.detail} class="text-[13.5px]" />

          <.section :if={@finding.steps} title="Steps to reproduce" qa="qa_finding_steps">
            <.markdown content={@finding.steps} class="text-[13px]" />
          </.section>

          <div :if={@finding.expected || @finding.observed} class="grid gap-4 sm:grid-cols-2">
            <.section :if={@finding.expected} title="Expected" qa="qa_finding_expected">
              <.markdown content={@finding.expected} class="text-[13px]" />
            </.section>

            <.section :if={@finding.observed} title="Observed" qa="qa_finding_observed">
              <.markdown content={@finding.observed} class="text-[13px]" />
            </.section>
          </div>

          <.section :if={@finding.evidence != []} title="Evidence" qa="qa_finding_evidence">
            <div class="space-y-4">
              <.evidence
                :for={{evidence, index} <- Enum.with_index(@finding.evidence)}
                task={@task}
                finding={@finding}
                evidence={evidence}
                index={index}
              />
            </div>
          </.section>

          <div
            :if={@finding.suggestion && @finding.status != :fixed}
            data-qa="qa_finding_suggestion"
            class="rounded-r-lg border border-l-2 border-slate-200 border-l-amber-500 dark:border-slate-700 dark:border-l-amber-500 bg-amber-50/50 dark:bg-amber-950/20 px-4 py-3.5"
          >
            <p class="text-[11px] font-extrabold uppercase tracking-wider text-amber-700 dark:text-amber-500">
              Suggested fix
            </p>
            <.markdown content={@finding.suggestion} class="mt-2 text-[13px]" />
          </div>

          <p
            :if={@finding.status != :fixed}
            data-qa="qa_finding_recommendation"
            class="flex items-center gap-2 text-xs text-slate-500 dark:text-slate-400"
          >
            <span class={["size-1.5 shrink-0 rounded-full", severity_dot(@finding)]} />
            {recommendation_line(@finding)}
          </p>
        </div>
      </div>

      <div class="shrink-0 flex items-center gap-2 px-7 py-3 border-t border-slate-200 dark:border-slate-700 text-xs">
        <button
          :for={{side, label} <- [previous: "← Previous", next: "Next finding →"]}
          type="button"
          id={"qa-finding-#{side}"}
          data-qa={"qa_finding_#{side}"}
          disabled={@neighbours[side] == nil}
          phx-click="select_finding"
          phx-target={@target}
          phx-value-key={@neighbours[side]}
          class="px-3 py-1.5 rounded-lg border border-slate-300 dark:border-slate-600 text-slate-600 dark:text-slate-400 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer disabled:opacity-40 disabled:cursor-not-allowed"
        >
          {label}
        </button>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :qa, :string, required: true
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <div data-qa={@qa}>
      <p class="text-[11px] font-extrabold uppercase tracking-wider text-slate-500 dark:text-slate-400">
        {@title}
      </p>
      <div class="mt-2">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :task, :any, required: true
  attr :finding, :any, required: true
  attr :evidence, :any, required: true
  attr :index, :integer, required: true

  # A screenshot is the whole point of the evidence: it is what tells the reader
  # QA saw this rather than reasoned it. Everything else is read as text, and a
  # file that is not an image is offered rather than rendered.
  defp evidence(assigns) do
    ~H"""
    <figure data-qa="qa_evidence" data-kind={@evidence.kind}>
      <img
        :if={@evidence.kind == :screenshot and @evidence.path}
        src={~p"/tasks/#{@task.id}/qa/#{@finding.key}/evidence/#{@index}"}
        alt={@evidence.name}
        loading="lazy"
        class="w-full rounded-xl border border-slate-200 dark:border-slate-700"
      />

      <pre
        :if={@evidence.text}
        class="overflow-x-auto rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 px-3.5 py-3 font-mono text-[11.5px] text-slate-700 dark:text-slate-300"
      ><%= @evidence.text %></pre>

      <a
        :if={@evidence.kind != :screenshot and @evidence.path}
        href={~p"/tasks/#{@task.id}/qa/#{@finding.key}/evidence/#{@index}"}
        target="_blank"
        rel="noopener"
        data-qa="qa_evidence_file"
        class="inline-flex items-center gap-1 text-[11.5px] font-semibold text-blue-600 dark:text-blue-400 hover:underline"
      >
        Open {@evidence.path} <.icon name="pi-arrow-up-right" class="size-3" />
      </a>

      <figcaption class="mt-1.5 text-[11.5px] text-slate-500 dark:text-slate-400">
        {@evidence.name}
      </figcaption>
    </figure>
    """
  end

  attr :checklist, :any, required: true
  attr :current, :any, required: true
  attr :frame, :any, required: true
  attr :driving, :map, required: true
  attr :task, :any, required: true
  attr :shots, :list, required: true
  attr :target, :any, required: true

  # A pass in flight, which is the one thing a spinner cannot show. What it is
  # looking at, where that is, and what Rail last did to it - the three things a
  # person standing behind someone testing would ask - and under it the pictures
  # taken for the row it is on.
  defp browser_viewer(assigns) do
    assigns = assign(assigns, :taken, assigns.current && shots_for(assigns.shots, assigns.current))

    ~H"""
    <div
      id="qa-running"
      data-qa="qa_running"
      class="flex-1 min-h-0 overflow-y-auto flex flex-col gap-3.5 p-4"
    >
      <div class="shrink-0 flex flex-wrap items-center gap-x-3.5 gap-y-2">
        <p class="flex items-center gap-2.5 text-sm font-bold text-slate-900 dark:text-slate-100">
          <span class="relative flex size-2">
            <span class="absolute inline-flex size-full rounded-full bg-blue-400 opacity-75 motion-safe:animate-ping" />
            <span class="relative inline-flex size-2 rounded-full bg-blue-500" />
          </span>
          Driving the application
        </p>

        <span
          :if={@checklist}
          data-qa="qa_drive_meta"
          class="font-mono text-[11.5px] text-slate-500 dark:text-slate-400"
        >
          {drive_meta(@checklist)}
        </span>
      </div>

      <div class="shrink-0 flex flex-col overflow-hidden rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-900">
        <div class="shrink-0 flex items-center gap-2.5 px-3 py-2 border-b border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/60">
          <span :for={_dot <- 1..3} class="size-2.5 rounded-full bg-slate-300 dark:bg-slate-600" />
          <span
            data-qa="qa_browser_url"
            class="flex-1 min-w-0 truncate rounded-md border border-slate-200 dark:border-slate-700 bg-slate-100 dark:bg-slate-900/70 px-2.5 py-1 font-mono text-[11px] text-slate-500 dark:text-slate-400"
          >
            {@driving.url || "about:blank"}
          </span>
          <span class="font-mono text-[11px] text-slate-400 dark:text-slate-500">1920 × 1080</span>
        </div>

        <div class="relative w-full aspect-video bg-slate-900">
          <img
            id="qa-screencast"
            data-qa="qa_screencast"
            phx-hook="QaScreencast"
            phx-update="ignore"
            src={@frame && "data:image/jpeg;base64,#{@frame}"}
            alt="What the QA browser is looking at"
            class="peer absolute inset-0 size-full object-contain"
          />

          <div
            :if={@frame == nil}
            data-qa="qa_screencast_waiting"
            class="absolute inset-0 flex flex-col items-center justify-center gap-3 bg-slate-900 peer-data-[live=true]:hidden"
          >
            <span class="size-5 rounded-full border-2 border-slate-700 border-t-blue-500 motion-safe:animate-spin" />
            <span class="font-mono text-[11.5px] text-slate-400">Waiting for the browser to paint.</span>
          </div>
        </div>

        <p
          data-qa="qa_doing"
          class="shrink-0 flex gap-2 px-3 py-2 border-t border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/60 font-mono text-[11.5px]"
        >
          <span class="shrink-0 text-blue-600 dark:text-blue-400">{verb(@driving.doing)}</span>
          <span class="min-w-0 truncate text-slate-600 dark:text-slate-300">{target(@driving.doing)}</span>
        </p>
      </div>

      <div :if={@taken not in [nil, []]} class="shrink-0" data-qa="qa_current_shots">
        <p class="mb-2 text-[10.5px] font-extrabold uppercase tracking-[0.14em] text-slate-400 dark:text-slate-500">
          Taken for this check
        </p>

        <div class="grid gap-2.5 grid-cols-[repeat(auto-fill,minmax(120px,1fr))]">
          <button
            :for={shot <- @taken}
            type="button"
            id={shot_id("qa-current-shot", shot)}
            data-qa="qa_current_shot"
            phx-click="select_shot"
            phx-target={@target}
            phx-value-file={shot.file}
            title={shot.name}
            class="overflow-hidden rounded-lg border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 text-left cursor-pointer hover:border-blue-400 dark:hover:border-blue-500"
          >
            <img
              src={~p"/tasks/#{@task.id}/qa/evidence/#{shot.file}"}
              alt={shot.name}
              loading="lazy"
              class="h-[66px] w-full object-cover object-top"
            />
            <span class="block truncate px-2 py-1.5 font-mono text-[10.5px] text-slate-500 dark:text-slate-400">
              {shot.name}
            </span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :task, :any, required: true
  attr :shot, :map, required: true
  attr :target, :any, required: true

  # A picture, full size, where the browser or the finding was. Closing it puts
  # back whatever was there before rather than navigating anywhere.
  defp shot_viewer(assigns) do
    ~H"""
    <div id="qa-shot-viewer" data-qa="qa_shot_viewer" class="flex-1 min-h-0 flex flex-col gap-3.5 p-4">
      <div class="shrink-0 flex items-center gap-3">
        <p
          data-qa="qa_shot_name"
          class="min-w-0 truncate text-sm font-bold text-slate-900 dark:text-slate-100"
        >
          {@shot.name}
        </p>

        <a
          href={~p"/tasks/#{@task.id}/qa/evidence/#{@shot.file}"}
          target="_blank"
          rel="noopener"
          class="shrink-0 inline-flex items-center gap-1 text-[11.5px] font-semibold text-blue-600 dark:text-blue-400 hover:underline"
        >
          Full size <.icon name="pi-arrow-up-right" class="size-3" />
        </a>

        <.close_pane target={@target} check={@shot.check} />
      </div>

      <div class="flex-1 min-h-[280px] overflow-auto rounded-xl border border-slate-200 dark:border-slate-700 bg-slate-900">
        <img
          src={~p"/tasks/#{@task.id}/qa/evidence/#{@shot.file}"}
          alt={@shot.name}
          class="w-full"
        />
      </div>
    </div>
    """
  end

  attr :task, :any, required: true
  attr :check, :any, required: true
  attr :shots, :list, required: true
  attr :target, :any, required: true

  # One row of the checklist, with the pictures the pass filed against it. This
  # is the answer to the question a reader actually has about a row that passed:
  # what did it look like when you looked at it.
  defp check_detail(assigns) do
    ~H"""
    <div id="qa-check-detail" data-qa="qa_check_detail" class="flex-1 min-w-0 min-h-0 flex flex-col">
      <div class="shrink-0 flex items-start gap-4 px-7 py-4 border-b border-slate-200 dark:border-slate-700">
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2.5">
            <span class={[
              "flex items-center gap-1.5 text-[11px] font-extrabold uppercase tracking-wider",
              check_tone(@check, nil)
            ]}>
              <.icon name={check_icon(@check, nil)} class="size-3.5" />
              {QaCheck.outcome_label(@check.outcome)}
            </span>

            <span
              :if={@check.group}
              data-qa="qa_check_detail_group"
              class="text-xs text-slate-500 dark:text-slate-400"
            >
              {@check.group}
            </span>
          </div>

          <h2 class="mt-2 text-lg font-bold text-slate-900 dark:text-slate-100">{@check.title}</h2>
        </div>
      </div>

      <div class="flex-1 min-h-0 overflow-y-auto px-7 py-6">
        <div class="max-w-4xl space-y-5">
          <div
            :if={@check.criterion}
            data-qa="qa_check_detail_criterion"
            class="rounded-r-lg border border-l-2 border-slate-200 border-l-blue-500 dark:border-slate-700 dark:border-l-blue-500 bg-blue-50/50 dark:bg-blue-950/20 px-4 py-3.5"
          >
            <p class="text-[11px] font-extrabold uppercase tracking-wider text-blue-700 dark:text-blue-400">
              Acceptance criterion
            </p>
            <.markdown content={@check.criterion} class="mt-2 text-[13px]" />
          </div>

          <p
            :if={@check.note}
            data-qa="qa_check_detail_note"
            class="text-[13.5px] text-slate-700 dark:text-slate-300"
          >
            {@check.note}
          </p>

          <.section title="Screenshots" qa="qa_check_detail_shots">
            <p
              :if={@shots == []}
              class="text-[13px] text-slate-500 dark:text-slate-400"
            >
              Nothing was filed against this row.
            </p>

            <div class="space-y-5">
              <figure :for={shot <- @shots} data-qa="qa_check_detail_shot">
                <button
                  type="button"
                  id={shot_id("qa-check-shot", shot)}
                  phx-click="select_shot"
                  phx-target={@target}
                  phx-value-file={shot.file}
                  class="block w-full cursor-pointer"
                >
                  <img
                    src={~p"/tasks/#{@task.id}/qa/evidence/#{shot.file}"}
                    alt={shot.name}
                    loading="lazy"
                    class="w-full rounded-xl border border-slate-200 dark:border-slate-700 hover:border-blue-400 dark:hover:border-blue-500"
                  />
                </button>

                <figcaption class="mt-1.5 text-[11.5px] text-slate-500 dark:text-slate-400">
                  {shot.name}
                </figcaption>
              </figure>
            </div>
          </.section>
        </div>
      </div>
    </div>
    """
  end

  attr :checklist, :any, required: true
  attr :check, :any, default: nil
  attr :current, :any, default: nil
  attr :shots, :list, default: []
  attr :target, :any, required: true

  # What the pass said it would do, before it knew any of the answers. A row with
  # no outcome yet is one it has not reached, which is as much of the story as the
  # ones it has - and while the pass is going, the first of those is where it is.
  #
  # Every row opens: what a reader wants from one is the pictures taken for it,
  # and those are too big for a column this wide.
  defp checklist_panel(assigns) do
    ~H"""
    <div id="qa-checklist" data-qa="qa_checklist" class="flex-1 flex flex-col">
      <div class="sticky top-0 z-10 shrink-0 px-4 py-3 border-b border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/95 backdrop-blur-sm">
        <div class="flex items-baseline gap-2">
          <span class="text-sm font-bold text-slate-900 dark:text-slate-100">Checklist</span>
          <span
            data-qa="qa_checklist_progress"
            class="text-[11.5px] text-slate-500 dark:text-slate-400"
          >
            {checklist_progress(@checklist)}
          </span>
        </div>

        <div
          :if={@checklist}
          class="mt-2.5 flex h-1 overflow-hidden rounded-full bg-slate-200 dark:bg-slate-700"
        >
          <span
            :for={
              {outcome, tone} <- [pass: "bg-emerald-500", fail: "bg-red-500", skipped: "bg-slate-400"]
            }
            class={tone}
            style={"width: #{share(@checklist, outcome)}%"}
          />
        </div>
      </div>

      <div :if={@checklist == nil} data-qa="qa_checklist_unwritten" class="px-4 py-5 space-y-4">
        <p class="text-[13px] leading-relaxed text-slate-500 dark:text-slate-400">
          QA writes its checklist before it opens anything, so this fills in within the first minute of a pass.
        </p>

        <!-- The rows that are coming, so the column reads as filling in rather
        than as empty. -->
        <div class="space-y-2.5" aria-hidden="true">
          <span
            :for={width <- ["w-11/12", "w-8/12", "w-10/12"]}
            class={[
              "block h-3 rounded bg-slate-200 dark:bg-slate-700 motion-safe:animate-pulse",
              width
            ]}
          />
        </div>
      </div>

      <div :if={@checklist} class="px-2 py-2">
        <div :for={{group, checks} <- QaChecklist.groups(@checklist)}>
          <p
            :if={group}
            data-qa="qa_check_group"
            class="px-2 pt-3 pb-1.5 text-[10.5px] font-extrabold uppercase tracking-[0.14em] text-slate-400 dark:text-slate-500"
          >
            {group}
          </p>

          <button
            :for={check <- checks}
            type="button"
            id={"qa-check-#{check.key}"}
            data-qa="qa_check"
            data-key={check.key}
            data-outcome={check.outcome}
            data-current={to_string(@current == check)}
            phx-click="select_check"
            phx-target={@target}
            phx-value-key={check.key}
            aria-current={to_string(@check == check)}
            class={[
              "w-full flex gap-2.5 rounded-lg px-3 py-2 text-left cursor-pointer",
              @check == check &&
                "bg-blue-50 dark:bg-blue-950/40 ring-1 ring-blue-300 dark:ring-blue-800",
              @check != check && @current == check &&
                "bg-blue-50/60 dark:bg-blue-950/20 ring-1 ring-blue-200 dark:ring-blue-900",
              @check != check && @current != check && "hover:bg-slate-100 dark:hover:bg-slate-800/60",
              @current != check && check.outcome == :pending && "opacity-60"
            ]}
          >
            <.icon
              name={check_icon(check, @current)}
              class={["mt-0.5 size-4 shrink-0", check_tone(check, @current)]}
            />

            <span class="min-w-0 flex-1">
              <span class={[
                "block text-[13px] leading-snug break-words",
                @current == check && "font-semibold text-slate-900 dark:text-slate-100",
                @current != check && "text-slate-700 dark:text-slate-300"
              ]}>
                {check.title}
              </span>
              <span
                data-qa="qa_check_note"
                class={["block font-mono text-[11px] leading-snug", check_tone(check, @current)]}
              >
                {check_state(check, @current)}
              </span>
            </span>

            <span
              :if={shots_for(@shots, check) != []}
              data-qa="qa_check_shots"
              class="mt-0.5 shrink-0 flex items-center gap-1 text-[10.5px] text-slate-400 dark:text-slate-500"
            >
              <.icon name="pi-image" class="size-3.5" />
              {length(shots_for(@shots, check))}
            </span>
          </button>
        </div>
      </div>

      <p
        :if={@checklist}
        data-qa="qa_checklist_tally"
        class="sticky bottom-0 mt-auto flex gap-3 px-4 py-2.5 border-t border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/95 backdrop-blur-sm font-mono text-[11.5px]"
      >
        <span :for={{text, tone} <- checklist_tally(@checklist)} class={tone}>{text}</span>
      </p>
    </div>
    """
  end

  attr :reported, :boolean, required: true
  attr :report, :any, required: true

  # Nothing running and nothing to read is two different situations: QA
  # exercised the change and raised nothing, or it stopped without reporting at
  # all - and only the first is a change anybody should send on. What it checked
  # is in the sidebar either way.
  defp qa_pending(assigns) do
    ~H"""
    <div
      id="qa-pending"
      data-qa="qa_pending"
      class="flex-1 min-h-0 flex flex-col items-center justify-center gap-5 p-8"
    >
      <div class="flex items-center justify-center size-14 rounded-2xl bg-blue-50 dark:bg-blue-950 text-blue-600 dark:text-blue-400 ring-1 ring-blue-100 dark:ring-blue-900">
        <.icon name={pending_icon(@reported)} class="size-7" />
      </div>

      <div class="text-center max-w-md">
        <h2 id="qa-pending-title" class="text-base font-semibold text-slate-900 dark:text-slate-100">
          {pending_title(@reported)}
        </h2>

        <p class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">
          {pending_body(@reported)}
        </p>
      </div>
    </div>
    """
  end

  # What this change broke, worst first; then what it only stands next to; then
  # what the human has already settled.
  defp load(socket) do
    findings = Pipeline.list_qa_findings(socket.assigns.task)
    selected = Enum.find(findings, List.first(findings), &(&1.key == socket.assigns.selected_key))
    checklist = checklist(socket.assigns.task)
    shots = Pipeline.list_qa_evidence(socket.assigns.task)
    running = Run.running?(socket.assigns.run)
    current = running && checklist && QaChecklist.current(checklist)
    driving = driving(running, socket.assigns.run, socket.assigns.task)

    socket
    |> assign(:findings, findings)
    |> assign(:selected, selected)
    |> assign(:selected_key, selected && selected.key)
    |> assign(:position, position(findings, selected))
    |> assign(:neighbours, neighbours(findings, selected))
    |> assign(:outstanding, Enum.filter(findings, &QaFinding.outstanding?/1))
    |> assign(:undecided, Enum.filter(findings, &QaFinding.undecided?/1))
    |> assign(:running, running)
    |> assign(:reported, reported?(socket.assigns.run))
    |> assign(:report, report(socket.assigns.task))
    |> assign(:checklist, checklist)
    |> assign(:frame, frame(driving, socket.assigns.task))
    |> assign(:shots, shots)
    |> assign(:shot, focused_shot(socket.assigns.focus, shots))
    |> assign(:check, focused_check(socket.assigns.focus, checklist))
    |> assign(:current, current)
    |> assign(:driving, driving)
    |> pane()
  end

  # Picking something is picking what the middle shows, so the panel reloads
  # around it rather than only swapping the pane: a row opened an hour into a
  # pass has pictures that were not there when it was drawn.
  defp focus(socket, focus), do: socket |> assign(:focus, focus) |> load()

  defp back(nil), do: nil
  defp back(key), do: {:check, key}

  # One thing in the middle, and what the human asked for beats what the pass is
  # doing: a picture opened while the browser drives stays open.
  defp pane(socket) do
    assign(socket, :pane, chosen(socket.assigns))
  end

  defp chosen(%{shot: %{}}), do: :shot
  defp chosen(%{focus: :summary, report: %QaReport{}, running: false}), do: :summary
  defp chosen(%{running: true, check: check, current: check}), do: :browser
  defp chosen(%{check: %QaCheck{}}), do: :check
  defp chosen(%{running: true}), do: :browser
  defp chosen(%{selected: %QaFinding{}}), do: :finding
  defp chosen(_nothing_picked), do: :pending

  defp focused_shot({:shot, file}, shots), do: Enum.find(shots, &(&1.file == file))
  defp focused_shot(_other, _shots), do: nil

  defp focused_check({:check, key}, %QaChecklist{checks: checks}), do: Enum.find(checks, &(&1.key == key))
  defp focused_check(_other, _checklist), do: nil

  # The pictures a row has, oldest first: a row's shots read as the order they
  # were taken in, unlike the roll underneath, where the newest is the news.
  defp shots_for(shots, %QaCheck{key: key}) do
    shots |> Enum.filter(&(&1.check == key)) |> Enum.reverse()
  end

  # A browser this pass has not touched yet has nothing to show, whatever is
  # still painted in it: a Chrome left open by the pass before this one would
  # otherwise read as this one's first page.
  defp frame(%{doing: nil}, %Task{}), do: nil
  defp frame(%{}, %Task{} = task), do: Tools.get_browser_frame(task)

  # Where the browser is and the last thing Rail actually did to it, both off the
  # run's own log. What is written there is what was executed rather than what the
  # agent asked for, so a step that went to the wrong element reads as the wrong
  # element.
  defp driving(false, _run, _task), do: %{doing: nil, url: nil}

  defp driving(true, %Run{} = run, %Task{} = task) do
    lines =
      run
      |> Pipeline.list_run_events(order: :desc, limit: 60)
      |> Enum.filter(&String.starts_with?(&1.line, "[qa] "))
      |> Enum.map(&(&1.line |> String.replace_prefix("[qa] ", "") |> String.trim()))

    %{doing: List.first(lines), url: Tools.get_browser_url(task) || Enum.find_value(lines, &opened/1)}
  end

  # `qa_goto` is the only thing that says where the browser went, and the newest
  # one is where it is.
  defp opened("goto " <> url), do: url
  defp opened(_other), do: nil

  # The log line reads as an instruction - `click "Save"` - so the word it starts
  # with is what Rail did and the rest is what it did it to.
  defp verb(nil), do: "idle"
  defp verb(line), do: line |> String.split(" ", parts: 2) |> List.first()

  defp target(nil), do: "Waiting for the first instruction."
  defp target(line), do: line |> String.split(" ", parts: 2) |> Enum.at(1, "")

  # The verdict belongs to the pass rather than to any row, so it is read off the
  # report every time the panel draws rather than stored.
  defp report(%Task{} = task), do: Pipeline.read_qa_report(task)

  # A pass that has not written its checklist yet is the first minute of every
  # pass, so the panel says so rather than treating it as a failure.
  defp checklist(%Task{} = task) do
    case Pipeline.read_qa_checklist(task) do
      {:ok, checklist} -> checklist
      {:error, :qa_checklist_not_found} -> nil
    end
  end

  # A run that has not latched has not reported, so its silence is not a clean
  # pass: a stopped QA agent and one that found nothing look identical otherwise,
  # and only one of them is a change anybody should send on.
  defp reported?(%Run{stage_outcome: :done}), do: true
  defp reported?(_not_concluded), do: false

  defp position(_findings, nil), do: 0
  defp position(findings, selected), do: Enum.find_index(findings, &(&1.key == selected.key)) + 1

  defp neighbours(_findings, nil), do: %{previous: nil, next: nil}

  defp neighbours(findings, selected) do
    index = Enum.find_index(findings, &(&1.key == selected.key))

    Map.new(
      %{
        previous: index > 0 && Enum.at(findings, index - 1).key,
        next: index < length(findings) - 1 && Enum.at(findings, index + 1).key
      },
      fn {side, key} -> {side, key || nil} end
    )
  end

  defp list_subtitle(%QaFinding{status: :fixed} = finding), do: "fixed · #{finding.check}"
  defp list_subtitle(%QaFinding{decision: :skip}), do: "dismissed"
  defp list_subtitle(%QaFinding{caused_by_change: false} = finding), do: "not this change · #{finding.check}"
  defp list_subtitle(%QaFinding{} = finding), do: finding.check

  # A settled finding is not asking for attention, so it stops shouting whatever
  # it was raised as.
  defp severity_dot(%QaFinding{status: :fixed}), do: "bg-emerald-500"
  defp severity_dot(%QaFinding{decision: :skip}), do: "bg-slate-300 dark:bg-slate-600"
  defp severity_dot(%QaFinding{severity: :blocker}), do: "bg-red-500"
  defp severity_dot(%QaFinding{severity: :major}), do: "bg-amber-500"
  defp severity_dot(%QaFinding{severity: :minor}), do: "bg-amber-400"
  defp severity_dot(%QaFinding{severity: :nit}), do: "bg-slate-400"

  defp severity_chip(%QaFinding{severity: :blocker}), do: "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300"

  defp severity_chip(%QaFinding{severity: :major}),
    do: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"

  defp severity_chip(%QaFinding{severity: :minor}),
    do: "bg-amber-50 text-amber-700 dark:bg-amber-950/60 dark:text-amber-400"

  defp severity_chip(%QaFinding{severity: :nit}), do: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"

  defp verdict_label(nil), do: "QA reported no verdict"
  defp verdict_label(verdict), do: QaReport.verdict_label(verdict)

  defp verdict_tone(:pass),
    do:
      "border-emerald-200 dark:border-emerald-900 bg-emerald-50 dark:bg-emerald-950/30 text-emerald-900 dark:text-emerald-200"

  defp verdict_tone(:concerns),
    do: "border-amber-200 dark:border-amber-900 bg-amber-50 dark:bg-amber-950/30 text-amber-900 dark:text-amber-200"

  defp verdict_tone(:fail),
    do: "border-red-200 dark:border-red-900 bg-red-50 dark:bg-red-950/30 text-red-900 dark:text-red-200"

  defp verdict_tone(nil),
    do: "border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 text-slate-700 dark:text-slate-300"

  defp verdict_dot(:pass), do: "bg-emerald-500"
  defp verdict_dot(:concerns), do: "bg-amber-500"
  defp verdict_dot(:fail), do: "bg-red-500"
  defp verdict_dot(nil), do: "bg-slate-400"

  defp decision("fix"), do: :fix
  defp decision("skip"), do: :skip

  defp recommendation_line(%QaFinding{recommendation: :fix, decision: :skip}) do
    "QA recommended fixing this. You dismissed it."
  end

  defp recommendation_line(%QaFinding{recommendation: :skip, decision: :fix}) do
    "QA would have left this. You chose to fix it."
  end

  defp recommendation_line(%QaFinding{recommendation: :fix}), do: "QA recommends fixing this."
  defp recommendation_line(%QaFinding{recommendation: :skip}), do: "QA recommends leaving this."

  defp pending_icon(true), do: "pi-seal-check"
  defp pending_icon(false), do: "pi-test-tube"

  defp pending_title(true), do: "Nothing to fix"
  defp pending_title(false), do: "No findings yet"

  defp pending_body(true) do
    "QA exercised the change and raised nothing. Send it on when you are happy with it."
  end

  defp pending_body(false) do
    "QA stopped without reporting. Send it a message in the conversation to pick up where it left off."
  end

  defp checklist_progress(nil), do: "not written yet"

  defp checklist_progress(%QaChecklist{} = checklist) do
    {run, total} = QaChecklist.progress(checklist)

    "#{run} of #{total}"
  end

  # The row the pass is on reads as itself rather than as one it has not reached.
  defp check_icon(check, check), do: "pi-circle-notch"
  defp check_icon(%QaCheck{outcome: :pending}, _current), do: "pi-circle-dashed"
  defp check_icon(%QaCheck{outcome: :pass}, _current), do: "pi-check-circle"
  defp check_icon(%QaCheck{outcome: :fail}, _current), do: "pi-x-circle"
  defp check_icon(%QaCheck{outcome: :skipped}, _current), do: "pi-minus-circle"

  defp check_tone(check, check), do: "text-blue-600 dark:text-blue-400"
  defp check_tone(%QaCheck{outcome: :pending}, _current), do: "text-slate-400 dark:text-slate-600"
  defp check_tone(%QaCheck{outcome: :pass}, _current), do: "text-emerald-600 dark:text-emerald-500"
  defp check_tone(%QaCheck{outcome: :fail}, _current), do: "text-red-600 dark:text-red-500"
  defp check_tone(%QaCheck{outcome: :skipped}, _current), do: "text-slate-400 dark:text-slate-500"

  # Its outcome and nothing else: what the pass said about a row is a sentence or
  # a paragraph, and forty of those is a column nobody can scan. The row opens.
  defp check_state(check, check), do: "running"

  defp check_state(%QaCheck{} = check, _current), do: String.downcase(QaCheck.outcome_label(check.outcome))

  # How much of the bar each outcome has earned. Pending rows are the gap. A
  # checklist with no rows never gets this far - one is refused on the way in.
  defp share(%QaChecklist{} = checklist, outcome) do
    QaChecklist.tally(checklist)[outcome] * 100 / length(checklist.checks)
  end

  defp checklist_tally(%QaChecklist{} = checklist) do
    counted = QaChecklist.tally(checklist)

    [
      {"#{counted.pass} passed", "text-emerald-600 dark:text-emerald-500"},
      {"#{counted.fail} failed", "text-red-600 dark:text-red-500"},
      {"#{counted.pending} left", "text-slate-500 dark:text-slate-400"}
    ]
  end

  # The filename carries an extension and the key it was filed under, and to
  # anything reading a selector a dot is a class and a `~` is a sibling. What is
  # between them is only the slug Rail made from the caption.
  defp shot_id(prefix, %{file: file}), do: "#{prefix}-#{file |> Path.rootname() |> String.replace("~", "-")}"

  defp drive_meta(%QaChecklist{} = checklist) do
    {run, total} = QaChecklist.progress(checklist)

    "check #{min(run + 1, total)} of #{total}"
  end

  defp message_for(:stage_running), do: "Something is still running on this task."
  defp message_for({:invalid_stage, stage}), do: "This task is at #{Task.stage_label(stage)}, not QA."
  defp message_for(:nothing_outstanding), do: "There is nothing left for the engineer to fix."
  defp message_for(:findings_outstanding), do: "Some findings are still outstanding. Fix them or dismiss them first."
  defp message_for(:findings_undecided), do: "Some findings have no decision yet. Rule on every one before sending."
  defp message_for(:no_engineer_role), do: "This project has no engineer to send the findings to."
  # coveralls-ignore-start (a refusal nobody has written a sentence for yet)
  defp message_for(reason), do: "Could not finish that: #{inspect(reason)}"
  # coveralls-ignore-stop
end
