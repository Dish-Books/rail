defmodule RailWeb.Live.QaStage do
  @moduledoc """
  What QA found driving the application, read one finding at a time.

  The same master and detail the review panel uses, because the human doing this
  is the human who just did that one, but what a finding holds is different: QA
  never saw the code, so there is no diff here. There is the check it came out
  of, the steps that reproduce it, what should have happened against what did,
  and the screenshots it took while it was there.

  Over the top of the list is QA's verdict on the whole change. It is advice, and
  it moves nothing: what the human decides finding by finding is what sends the
  change back or on, exactly as it is in review. A verdict that says `fail` next
  to findings a person has read and dismissed is a change that ships.

  Neither button appears while anything is unruled. Sending then would drop a
  finding from the round with nobody having said to, and going on to demo would
  read a silence as a dismissal.

  What this change broke sorts above what it merely stands next to. Both are
  worth reporting and only one of them is usually this branch's to fix.
  """
  use RailWeb, :live_component

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.QaReport
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:selected_key, fn -> nil end)

    {:ok, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="qa-stage" data-qa="qa-stage" class="contents">
      <.task_layout task={@task} run={@run} title={@task.issue.title} flush={@findings != []}>
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

        <.qa_pending :if={@findings == []} running={@running} reported={@reported} report={@report} />

        <div :if={@findings != []} id="qa-findings" data-qa="qa_findings" class="h-full flex flex-col">
          <.verdict_banner :if={@report} report={@report} />

          <div class="flex-1 min-h-0 flex">
            <.finding_list findings={@findings} selected={@selected} target={@myself} />
            <.finding_detail
              task={@task}
              finding={@selected}
              position={@position}
              count={length(@findings)}
              decidable={@approvable and not @running}
              neighbours={@neighbours}
              target={@myself}
            />
          </div>
        </div>

        <:sidebar>{render_slot(@sidebar)}</:sidebar>
      </.task_layout>
    </div>
    """
  end

  @impl true
  def handle_event("select_finding", %{"key" => key}, socket) do
    socket = socket |> assign(:selected_key, key) |> load()

    {:noreply, socket}
  end

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

  # What QA thought of the change as a whole, over the top of what it listed.
  # Coloured, because the one thing a reader wants at a glance is whether this
  # worked.
  defp verdict_banner(assigns) do
    ~H"""
    <div
      data-qa="qa_verdict"
      data-verdict={@report.verdict}
      class={[
        "shrink-0 px-7 py-4 border-b",
        verdict_tone(@report.verdict)
      ]}
    >
      <p class="flex items-center gap-2.5">
        <span class={["size-2 shrink-0 rounded-full", verdict_dot(@report.verdict)]} />
        <span data-qa="qa_verdict_label" class="text-sm font-bold">
          {verdict_label(@report.verdict)}
        </span>
      </p>

      <.markdown :if={@report.summary} content={@report.summary} class="mt-2 text-[13px]" />

      <div :if={@report.not_checked} data-qa="qa_not_checked" class="mt-3">
        <p class="text-[11px] font-extrabold uppercase tracking-wider opacity-70">
          What it could not check
        </p>
        <.markdown content={@report.not_checked} class="mt-1 text-[12.5px] opacity-80" />
      </div>
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
      class="w-[300px] shrink-0 flex flex-col border-r border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/30"
    >
      <div class="flex items-baseline gap-2 px-4 py-3 border-b border-slate-200 dark:border-slate-700">
        <span class="text-sm font-bold text-slate-900 dark:text-slate-100">Findings</span>
        <span class="text-xs text-slate-500 dark:text-slate-400">{length(@findings)}</span>
      </div>

      <div class="flex-1 min-h-0 overflow-y-auto p-2 space-y-1">
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

      <p
        data-qa="qa_finding_tally"
        class="px-4 py-3 border-t border-slate-200 dark:border-slate-700 text-xs text-slate-500 dark:text-slate-400"
      >
        {tally(@findings)}
      </p>
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
    <div id="qa-finding-detail" data-qa="qa_finding_detail" class="flex-1 min-w-0 flex flex-col">
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

  attr :running, :boolean, required: true
  attr :reported, :boolean, required: true
  attr :report, :any, required: true

  # No findings is three different situations: QA is still driving the app, it
  # exercised the change and found nothing, or it stopped without reporting at
  # all - and only the middle one is a change anybody should send on.
  defp qa_pending(assigns) do
    ~H"""
    <div id="qa-pending" data-qa="qa_pending" class="flex flex-col items-center gap-10 py-10">
      <div class="flex flex-col items-center text-center max-w-md">
        <div class="relative flex items-center justify-center size-14 rounded-2xl bg-blue-50 dark:bg-blue-950 text-blue-600 dark:text-blue-400 ring-1 ring-blue-100 dark:ring-blue-900">
          <span
            :if={@running}
            class="absolute inset-0 rounded-2xl ring-2 ring-blue-400/40 motion-safe:animate-ping"
          />
          <.icon name={pending_icon(@running, @reported)} class="size-7" />
        </div>

        <h2
          id="qa-pending-title"
          class="mt-5 text-base font-semibold text-slate-900 dark:text-slate-100"
        >
          {pending_title(@running, @reported)}
        </h2>

        <p class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">
          {pending_body(@running, @reported)}
        </p>

        <.markdown
          :if={@report && @report.summary}
          content={@report.summary}
          class="mt-4 text-left text-[13px]"
        />
      </div>

      <div class="w-full max-w-3xl space-y-3" aria-hidden="true">
        <div class={[
          "h-4 w-1/3 rounded bg-slate-200 dark:bg-slate-800",
          @running && "motion-safe:animate-pulse"
        ]} />
        <div
          :for={width <- ["w-full", "w-11/12", "w-4/5"]}
          class={["h-2.5 rounded bg-slate-100 dark:bg-slate-800/60", width]}
        />
      </div>
    </div>
    """
  end

  # What this change broke, worst first; then what it only stands next to; then
  # what the human has already settled.
  defp load(socket) do
    findings = Pipeline.list_qa_findings(socket.assigns.task)
    selected = Enum.find(findings, List.first(findings), &(&1.key == socket.assigns.selected_key))

    socket
    |> assign(:findings, findings)
    |> assign(:selected, selected)
    |> assign(:selected_key, selected && selected.key)
    |> assign(:position, position(findings, selected))
    |> assign(:neighbours, neighbours(findings, selected))
    |> assign(:outstanding, Enum.filter(findings, &QaFinding.outstanding?/1))
    |> assign(:undecided, Enum.filter(findings, &QaFinding.undecided?/1))
    |> assign(:running, Run.running?(socket.assigns.run))
    |> assign(:reported, reported?(socket.assigns.run))
    |> assign(:report, report(socket.assigns.task))
  end

  # The verdict belongs to the pass rather than to any row, so it is read off the
  # report every time the panel draws rather than stored.
  defp report(%Task{} = task), do: Pipeline.read_qa_report(task)

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

  defp tally(findings) do
    dismissed = Enum.count(findings, &(&1.decision == :skip and &1.status != :fixed))
    fixed = Enum.count(findings, &(&1.status == :fixed))
    undecided = Enum.count(findings, &QaFinding.undecided?/1)
    outstanding = Enum.count(findings, &QaFinding.outstanding?/1)

    [{undecided, "to decide"}, {outstanding, "to fix"}, {fixed, "fixed"}, {dismissed, "dismissed"}]
    |> Enum.reject(fn {count, _word} -> count == 0 end)
    |> Enum.map_join(" · ", fn {count, word} -> "#{count} #{word}" end)
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

  defp pending_icon(true, _reported), do: "pi-flask"
  defp pending_icon(false, true), do: "pi-seal-check"
  defp pending_icon(false, false), do: "pi-test-tube"

  defp pending_title(true, _reported), do: "Driving the application"
  defp pending_title(false, true), do: "Nothing to fix"
  defp pending_title(false, false), do: "No findings yet"

  defp pending_body(true, _reported) do
    "QA is working the change in a running app against the ticket's acceptance criteria. Whatever it finds appears here as soon as it reports."
  end

  defp pending_body(false, true) do
    "QA exercised the change and raised nothing. Send it on when you are happy with it."
  end

  defp pending_body(false, false) do
    "QA stopped without reporting. Send it a message in the conversation to pick up where it left off."
  end

  defp message_for(:stage_running), do: "Something is still running on this task."
  defp message_for({:invalid_stage, stage}), do: "This task is at #{Task.stage_label(stage)}, not QA."
  defp message_for(:nothing_outstanding), do: "There is nothing left for the engineer to fix."
  defp message_for(:findings_outstanding), do: "Some findings are still outstanding. Fix them or dismiss them first."
  defp message_for(:findings_undecided), do: "Some findings have no decision yet. Rule on every one before sending."
  defp message_for(:no_engineer_role), do: "This project has no engineer to send the findings to."
  defp message_for(reason), do: "Could not finish that: #{inspect(reason)}"
end
