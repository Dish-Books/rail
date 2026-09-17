defmodule RailWeb.Live.ReviewStage do
  @moduledoc """
  What the reviewer found, read one finding at a time.

  Findings are a list to work through rather than a wall to read, so the pane is
  master and detail: every finding down the left with its severity and where it
  is, and the one being read on the right with the reasoning, the change it
  points at, and what would settle it. The reviewer recommends and the human
  overrules, so each finding carries both, and the two buttons in the header are
  the only two things that can follow - back to the engineer with what is
  outstanding, or on to QA when nothing is.

  Nothing about a dismissed finding is hidden. "What is left" only means
  something next to what was dealt with: six findings with five dismissed reads
  very differently from one lone nit.
  """
  use RailWeb, :live_component

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:error, fn -> nil end)
      |> assign_new(:selected_key, fn -> nil end)
      |> assign_new(:engineer_tab, fn -> nil end)

    socket = socket |> load() |> load_hunk()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="review-stage" data-qa="review-stage" class="contents">
      <.task_layout task={@task} run={@run} title={@task.issue.title} flush={@findings != []}>
        <:tabs>{render_slot(@tabs)}</:tabs>

        <:actions>
          {render_slot(@actions)}

          <button
            :if={@approvable and @reviewed and @outstanding != []}
            type="button"
            id="send-findings-to-engineer"
            data-qa="send_findings_to_engineer"
            phx-click="send_findings_to_engineer"
            phx-target={@myself}
            class="px-4 py-2 rounded-lg text-sm font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs"
          >
            Send {length(@outstanding)} back to engineer
          </button>

          <button
            :if={@approvable and @reviewed and @outstanding == []}
            type="button"
            id="send-to-qa"
            data-qa="send_to_qa"
            phx-click="send_to_qa"
            phx-target={@myself}
            class="px-4 py-2 rounded-lg text-sm font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs"
          >
            Send to QA
          </button>
        </:actions>

        <:alerts :if={@error}>
          <p id="review-error" data-qa="review_error" class="text-xs text-red-600 dark:text-red-500">
            {@error}
          </p>
        </:alerts>

        <.review_pending :if={@findings == []} running={@running} reviewed={@reviewed} />

        <div :if={@findings != []} id="review-findings" data-qa="review_findings" class="h-full flex">
          <.finding_list findings={@findings} selected={@selected} target={@myself} />
          <.finding_detail
            finding={@selected}
            position={@position}
            count={length(@findings)}
            hunk={@hunk}
            diff_link={diff_link(@task, @engineer_tab, @hunk)}
            decidable={@approvable and not @running}
            neighbours={@neighbours}
            target={@myself}
          />
        </div>

        <:sidebar>{render_slot(@sidebar)}</:sidebar>
      </.task_layout>
    </div>
    """
  end

  @impl true
  def handle_event("select_finding", %{"key" => key}, socket) do
    socket = socket |> assign(:selected_key, key) |> load() |> load_hunk()

    {:noreply, socket}
  end

  def handle_event("decide", %{"key" => key, "decision" => decision}, socket) do
    finding = Enum.find(socket.assigns.findings, &(&1.key == key))

    socket =
      case Pipeline.decide_review_finding(finding, decision(decision)) do
        {:ok, _decided} -> socket |> assign(:error, nil) |> load()
        {:error, reason} -> assign(socket, :error, message_for(reason))
      end

    {:noreply, socket}
  end

  def handle_event("send_findings_to_engineer", _params, socket) do
    case Pipeline.send_findings_to_engineer(socket.assigns.run) do
      {:ok, _run} ->
        send(self(), :task_changed)
        {:noreply, assign(socket, :error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, message_for(reason))}
    end
  end

  def handle_event("send_to_qa", _params, socket) do
    case Pipeline.send_to_qa(socket.assigns.run) do
      {:ok, _run} ->
        send(self(), :task_changed)
        {:noreply, assign(socket, :error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, message_for(reason))}
    end
  end

  attr :findings, :list, required: true
  attr :selected, :any, required: true
  attr :target, :any, required: true

  defp finding_list(assigns) do
    ~H"""
    <div
      id="review-finding-list"
      data-qa="review_finding_list"
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
          id={"finding-#{finding.key}"}
          data-qa="review_finding"
          data-state={ReviewFinding.state(finding)}
          phx-click="select_finding"
          phx-target={@target}
          phx-value-key={finding.key}
          aria-current={to_string(@selected.key == finding.key)}
          class={[
            "w-full flex gap-2.5 px-3 py-2.5 rounded-lg text-left cursor-pointer",
            @selected.key == finding.key &&
              "bg-blue-50 dark:bg-blue-950/40 ring-1 ring-blue-300 dark:ring-blue-800",
            @selected.key != finding.key && "hover:bg-slate-100 dark:hover:bg-slate-800/60",
            ReviewFinding.state(finding) == :dismissed && "opacity-60"
          ]}
        >
          <span class={["mt-1.5 size-1.5 shrink-0 rounded-full", severity_dot(finding)]} />

          <span class="min-w-0 flex-1">
            <span class={[
              "block text-[13px] leading-snug",
              @selected.key == finding.key &&
                "font-semibold text-slate-900 dark:text-slate-100",
              @selected.key != finding.key && "text-slate-700 dark:text-slate-300",
              ReviewFinding.state(finding) == :dismissed && "line-through"
            ]}>
              {finding.title}
            </span>
            <span class="block truncate font-mono text-[10px] text-slate-500 dark:text-slate-400">
              {list_subtitle(finding)}
            </span>
          </span>
        </button>
      </div>

      <p
        data-qa="review_finding_tally"
        class="px-4 py-3 border-t border-slate-200 dark:border-slate-700 text-xs text-slate-500 dark:text-slate-400"
      >
        {tally(@findings)}
      </p>
    </div>
    """
  end

  attr :finding, :any, required: true
  attr :position, :integer, required: true
  attr :count, :integer, required: true
  attr :hunk, :any, required: true
  attr :diff_link, :any, required: true
  attr :decidable, :boolean, required: true
  attr :neighbours, :map, required: true
  attr :target, :any, required: true

  defp finding_detail(assigns) do
    ~H"""
    <div
      id="review-finding-detail"
      data-qa="review_finding_detail"
      class="flex-1 min-w-0 flex flex-col"
    >
      <div class="shrink-0 flex items-start gap-4 px-7 py-4 border-b border-slate-200 dark:border-slate-700">
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2.5">
            <span class={[
              "rounded px-2 py-0.5 text-[10px] font-extrabold uppercase tracking-wider",
              severity_chip(@finding)
            ]}>
              {ReviewFinding.severity_label(@finding.severity)}
            </span>
            <span data-qa="finding_position" class="text-xs text-slate-500 dark:text-slate-400">
              {@position} of {@count}
            </span>
            <span
              :if={@finding.decision == nil and @finding.status != :fixed}
              data-qa="finding_undecided"
              class="text-xs font-semibold text-blue-600 dark:text-blue-400"
            >
              Needs your call
            </span>
            <span
              :if={@finding.decision == :skip}
              data-qa="finding_dismissed"
              class="text-xs font-semibold text-slate-500 dark:text-slate-400"
            >
              Dismissed
            </span>
            <span
              :if={@finding.status == :fixed}
              data-qa="finding_fixed"
              class="text-xs font-semibold text-emerald-600 dark:text-emerald-500"
            >
              Fixed
            </span>
            <span
              :if={@finding.status == :not_fixed}
              data-qa="finding_not_fixed"
              class="text-xs font-semibold text-amber-600 dark:text-amber-500"
            >
              Still not fixed
            </span>
          </div>

          <h2 class="mt-2 text-lg font-bold text-slate-900 dark:text-slate-100">
            {@finding.title}
          </h2>

          <p
            :if={@finding.file}
            data-qa="finding_location"
            class="mt-1.5 font-mono text-[11.5px] text-slate-500 dark:text-slate-400"
          >
            {location(@finding)}
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
          <.markdown :if={@finding.detail} content={@finding.detail} class="text-[13.5px]" />

          <div
            :if={@finding.suggestion && @finding.status != :fixed}
            data-qa="finding_suggestion"
            class="rounded-r-lg border border-l-2 border-slate-200 border-l-amber-500 dark:border-slate-700 dark:border-l-amber-500 bg-amber-50/50 dark:bg-amber-950/20 px-4 py-3.5"
          >
            <p class="text-[11px] font-extrabold uppercase tracking-wider text-amber-700 dark:text-amber-500">
              Suggested fix
            </p>
            <.markdown content={@finding.suggestion} class="mt-2 text-[13px]" />
          </div>

          <div
            :if={@hunk}
            data-qa="finding_diff"
            class="rounded-xl border border-slate-200 dark:border-slate-700 overflow-hidden"
          >
            <div class="flex items-center gap-2.5 px-3.5 py-2.5 bg-slate-100 dark:bg-slate-800 border-b border-slate-200 dark:border-slate-700">
              <span class="min-w-0 truncate font-mono text-[11.5px] text-slate-700 dark:text-slate-300">
                {@hunk.display_path}
              </span>
              <.diff_stat additions={@hunk.additions} deletions={@hunk.deletions} font_size={11} />

              <!-- The whole change lives on the engineer's tab, so the finding
              points there rather than growing a second diff pane of its own. -->
              <.link
                :if={@diff_link}
                patch={@diff_link}
                id="finding-open-in-diff"
                data-qa="finding_open_in_diff"
                class="ml-auto shrink-0 inline-flex items-center gap-1 text-[11.5px] font-semibold text-blue-600 dark:text-blue-400 hover:underline"
              >
                Open diff <.icon name="pi-arrow-up-right" class="size-3" />
              </.link>
            </div>

            <.diff_hunk rows={@hunk.rows} />

            <p
              :if={elided(@hunk) != nil}
              data-qa="finding_other_hunks"
              class="px-3.5 py-2 border-t border-slate-200 dark:border-slate-700 bg-slate-50 dark:bg-slate-800/40 text-[11.5px] text-slate-500 dark:text-slate-400"
            >
              {elided(@hunk)}
            </p>
          </div>

          <p
            :if={@finding.status != :fixed}
            data-qa="finding_recommendation"
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
          id={"finding-#{side}"}
          data-qa={"finding_#{side}"}
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

  attr :running, :boolean, required: true
  attr :reviewed, :boolean, required: true

  # No findings is three different situations: the reviewer is still reading, it
  # read the change and raised nothing, or it stopped without reporting at all -
  # and only the middle one is a change anybody should send on.
  defp review_pending(assigns) do
    ~H"""
    <div id="review-pending" data-qa="review_pending" class="flex flex-col items-center gap-10 py-10">
      <div class="flex flex-col items-center text-center max-w-md">
        <div class="relative flex items-center justify-center size-14 rounded-2xl bg-blue-50 dark:bg-blue-950 text-blue-600 dark:text-blue-400 ring-1 ring-blue-100 dark:ring-blue-900">
          <span
            :if={@running}
            class="absolute inset-0 rounded-2xl ring-2 ring-blue-400/40 motion-safe:animate-ping"
          />
          <.icon name={pending_icon(@running, @reviewed)} class="size-7" />
        </div>

        <h2
          id="review-pending-title"
          class="mt-5 text-base font-semibold text-slate-900 dark:text-slate-100"
        >
          {pending_title(@running, @reviewed)}
        </h2>

        <p class="mt-2 text-sm leading-relaxed text-slate-500 dark:text-slate-400">
          {pending_body(@running, @reviewed)}
        </p>
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

  # Worst first, and what is settled last, so the list reads as the order to work
  # through it in.
  defp load(socket) do
    findings = Pipeline.list_review_findings(socket.assigns.task)
    selected = Enum.find(findings, List.first(findings), &(&1.key == socket.assigns.selected_key))

    socket
    |> assign(:findings, findings)
    |> assign(:selected, selected)
    |> assign(:selected_key, selected && selected.key)
    |> assign(:position, position(findings, selected))
    |> assign(:neighbours, neighbours(findings, selected))
    |> assign(:outstanding, Enum.filter(findings, &ReviewFinding.outstanding?/1))
    |> assign(:running, Run.running?(socket.assigns.run))
    |> assign(:reviewed, reviewed?(socket.assigns.run))
  end

  # The change a finding points at is read off the worktree, so it is loaded only
  # for the finding being read rather than for all of them.
  defp load_hunk(%{assigns: %{selected: %ReviewFinding{file: file} = finding}} = socket) when is_binary(file) do
    assign(socket, :hunk, Git.load_diff_hunk(socket.assigns.current_scope, socket.assigns.task, file, finding.line))
  end

  defp load_hunk(socket), do: assign(socket, :hunk, nil)

  # A run that has not latched has not reported, so its silence is not a clean
  # review: a stopped reviewer and one that found nothing look identical
  # otherwise, and only one of them is a change anybody should send to QA.
  defp reviewed?(%Run{stage_outcome: :done}), do: true
  defp reviewed?(_not_concluded), do: false

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
    undecided = Enum.count(findings, &ReviewFinding.undecided?/1)
    outstanding = Enum.count(findings, &ReviewFinding.outstanding?/1)

    [{undecided, "to decide"}, {outstanding, "to fix"}, {fixed, "fixed"}, {dismissed, "dismissed"}]
    |> Enum.reject(fn {count, _word} -> count == 0 end)
    |> Enum.map_join(" · ", fn {count, word} -> "#{count} #{word}" end)
  end

  defp list_subtitle(%ReviewFinding{status: :fixed} = finding), do: "fixed · #{location(finding)}"
  defp list_subtitle(%ReviewFinding{decision: :skip}), do: "dismissed"
  defp list_subtitle(%ReviewFinding{file: nil}), do: "no file"
  defp list_subtitle(%ReviewFinding{} = finding), do: location(finding)

  defp location(%ReviewFinding{file: nil}), do: ""
  defp location(%ReviewFinding{file: file, line: nil}), do: file
  defp location(%ReviewFinding{file: file, line: line}), do: "#{file}:#{line}"

  # A settled finding is not asking for attention, so it stops shouting whatever
  # it was raised as.
  defp severity_dot(%ReviewFinding{status: :fixed}), do: "bg-emerald-500"
  defp severity_dot(%ReviewFinding{decision: :skip}), do: "bg-slate-300 dark:bg-slate-600"
  defp severity_dot(%ReviewFinding{severity: :blocker}), do: "bg-red-500"
  defp severity_dot(%ReviewFinding{severity: :major}), do: "bg-amber-500"
  defp severity_dot(%ReviewFinding{severity: :minor}), do: "bg-amber-400"
  defp severity_dot(%ReviewFinding{severity: :nit}), do: "bg-slate-400"

  defp severity_chip(%ReviewFinding{severity: :blocker}), do: "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300"

  defp severity_chip(%ReviewFinding{severity: :major}),
    do: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"

  defp severity_chip(%ReviewFinding{severity: :minor}),
    do: "bg-amber-50 text-amber-700 dark:bg-amber-950/60 dark:text-amber-400"

  defp severity_chip(%ReviewFinding{severity: :nit}),
    do: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"

  # Only once the engineer has a tab to land on, and only for a file the branch
  # actually changed - a link to a file the diff does not hold lands on nothing.
  defp diff_link(%Task{} = task, engineer_tab, %{path: path}) when is_binary(engineer_tab) do
    ~p"/tasks/#{task.id}?tab=#{engineer_tab}&file=#{path}"
  end

  defp diff_link(_task, _no_tab, _no_hunk), do: nil

  # Only a window around the line the finding names is shown, so the pane says
  # what it left out rather than letting the reader assume that is the whole of
  # the change.
  defp elided(%{hidden_lines: hidden, other_hunks: others}) do
    [{hidden, "line", "lines"}, {others, "other change", "other changes"}]
    |> Enum.reject(fn {count, _one, _many} -> count == 0 end)
    |> Enum.map_join(" and ", fn
      {1, one, _many} -> "1 more #{one}"
      {count, _one, many} -> "#{count} more #{many}"
    end)
    |> case do
      "" -> nil
      parts -> "#{parts} in this file."
    end
  end

  defp decision("fix"), do: :fix
  defp decision("skip"), do: :skip

  defp recommendation_line(%ReviewFinding{recommendation: :fix, decision: :skip}) do
    "The reviewer recommended fixing this. You dismissed it."
  end

  defp recommendation_line(%ReviewFinding{recommendation: :skip, decision: :fix}) do
    "The reviewer would have left this. You chose to fix it."
  end

  defp recommendation_line(%ReviewFinding{recommendation: :fix}), do: "The reviewer recommends fixing this."
  defp recommendation_line(%ReviewFinding{recommendation: :skip}), do: "The reviewer recommends leaving this."

  defp pending_icon(true, _reviewed), do: "pi-magnifying-glass"
  defp pending_icon(false, true), do: "pi-seal-check"
  defp pending_icon(false, false), do: "pi-eye"

  defp pending_title(true, _reviewed), do: "Reading the change"
  defp pending_title(false, true), do: "Nothing to fix"
  defp pending_title(false, false), do: "No findings yet"

  defp pending_body(true, _reviewed) do
    "The reviewer is reading the branch against the plan it was built from. Whatever it finds appears here as soon as it reports."
  end

  defp pending_body(false, true) do
    "The reviewer read the change and raised nothing. Send it to QA when you are happy with it."
  end

  defp pending_body(false, false) do
    "The reviewer stopped without reporting. Send it a message in the conversation to pick up where it left off."
  end

  defp message_for(:stage_running), do: "Something is still running on this task."
  defp message_for({:invalid_stage, stage}), do: "This task is at #{Task.stage_label(stage)}, not review."
  defp message_for(:nothing_outstanding), do: "There is nothing left for the engineer to fix."
  defp message_for(:findings_outstanding), do: "Some findings are still outstanding. Fix them or dismiss them first."
  defp message_for(:findings_undecided), do: "Some findings have no decision yet. Rule on every one before sending."
  defp message_for(:no_engineer_role), do: "This project has no engineer to send the findings to."
  defp message_for(reason), do: "Could not finish that: #{inspect(reason)}"
end
