defmodule RailWeb.Live.ReviewStage do
  @moduledoc """
  What the reviewer found, and the two decisions a human takes on it.

  Every finding is here whatever has become of it, because "what is left" only
  means something next to what was dealt with: a change with six findings and
  five dismissed reads very differently from one with a single nit. The reviewer
  recommends and the human overrides, so each row carries both, and the two
  buttons in the header are exactly the two things that can follow - back to the
  engineer with what is outstanding, or on to QA when nothing is.
  """
  use RailWeb, :live_component

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  # Worst news first: what the engineer tried and did not fix, then what it has
  # not seen, then what is settled.
  @group_order [:not_fixed, :to_fix, :fixed, :dismissed]

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:error, fn -> nil end)

    {:ok, load(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="review-stage" data-qa="review-stage" class="contents">
      <.task_layout task={@task} run={@run} title={@task.issue.title}>
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

        <div
          :if={@findings != []}
          id="review-findings"
          data-qa="review_findings"
          class="max-w-3xl mx-auto space-y-8 select-text"
        >
          <section
            :for={group <- @groups}
            id={"review-group-#{group.state}"}
            data-qa={"review_group_#{group.state}"}
          >
            <h2 class="flex items-baseline gap-2 text-sm font-semibold text-slate-900 dark:text-slate-100">
              {group.label}
              <span class="text-xs font-normal text-slate-500 dark:text-slate-400">
                {length(group.findings)}
              </span>
            </h2>

            <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">{group.hint}</p>

            <ul class="mt-3 space-y-3">
              <.finding
                :for={finding <- group.findings}
                finding={finding}
                decidable={@approvable and not @running}
                target={@myself}
              />
            </ul>
          </section>
        </div>

        <:sidebar>{render_slot(@sidebar)}</:sidebar>
      </.task_layout>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_decision", %{"finding_id" => finding_id}, socket) do
    finding = Enum.find(socket.assigns.findings, &(&1.id == finding_id))

    socket =
      case Pipeline.decide_review_finding(finding, flip(finding.decision)) do
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

  attr :finding, :any, required: true
  attr :decidable, :boolean, required: true
  attr :target, :any, required: true

  defp finding(assigns) do
    ~H"""
    <li
      id={"finding-#{@finding.id}"}
      data-qa="review_finding"
      data-state={ReviewFinding.state(@finding)}
      class="rounded-xl border border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-900 p-4"
    >
      <div class="flex items-start gap-3">
        <span class={[
          "mt-0.5 shrink-0 rounded-md px-2 py-0.5 text-[11px] font-semibold uppercase tracking-wide",
          severity_class(@finding.severity)
        ]}>
          {ReviewFinding.severity_label(@finding.severity)}
        </span>

        <div class="min-w-0 flex-1">
          <h3 class="text-sm font-semibold text-slate-900 dark:text-slate-100">{@finding.title}</h3>

          <p class="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1 font-mono text-[11px] text-slate-500 dark:text-slate-400">
            <span data-qa="finding_key">{@finding.key}</span>
            <span :if={@finding.file} data-qa="finding_location">{location(@finding)}</span>
          </p>
        </div>

        <button
          :if={@decidable}
          type="button"
          id={"toggle-decision-#{@finding.id}"}
          data-qa="toggle_decision"
          phx-click="toggle_decision"
          phx-target={@target}
          phx-value-finding_id={@finding.id}
          class="shrink-0 rounded-lg border border-slate-300 dark:border-slate-600 px-3 py-1.5 text-xs font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer"
        >
          {toggle_label(@finding.decision)}
        </button>
      </div>

      <.markdown :if={@finding.detail} content={@finding.detail} class="mt-3 text-sm" />

      <p class="mt-3 text-[11px] text-slate-500 dark:text-slate-400" data-qa="finding_recommendation">
        {recommendation_line(@finding)}
      </p>
    </li>
    """
  end

  attr :running, :boolean, required: true
  attr :reviewed, :boolean, required: true

  # No findings is three different situations: the reviewer is still reading, it
  # read the change and raised nothing, or it stopped without reporting at all -
  # and only the middle one is a change anybody should send on.
  defp review_pending(assigns) do
    ~H"""
    <div
      id="review-pending"
      data-qa="review_pending"
      class="flex flex-col items-center gap-10 py-10"
    >
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

  defp load(socket) do
    findings = Pipeline.list_review_findings(socket.assigns.task)

    socket
    |> assign(:findings, findings)
    |> assign(:groups, groups(findings))
    |> assign(:outstanding, Enum.filter(findings, &ReviewFinding.outstanding?/1))
    |> assign(:running, Run.running?(socket.assigns.run))
    |> assign(:reviewed, reviewed?(socket.assigns.run))
  end

  # A run that has not latched has not reported, so its silence is not a clean
  # review: a stopped reviewer and one that found nothing look identical
  # otherwise, and only one of them is a change anybody should send to QA.
  defp reviewed?(%Run{stage_outcome: :done}), do: true
  defp reviewed?(_not_concluded), do: false

  defp groups(findings) do
    grouped = Enum.group_by(findings, &ReviewFinding.state/1)

    for state <- @group_order, findings = Map.get(grouped, state, []), findings != [] do
      %{state: state, label: group_label(state), hint: group_hint(state), findings: findings}
    end
  end

  defp group_label(:not_fixed), do: "Still not fixed"
  defp group_label(:to_fix), do: "To fix"
  defp group_label(:fixed), do: "Fixed"
  defp group_label(:dismissed), do: "Dismissed"

  defp group_hint(:not_fixed), do: "The engineer has been round these and the reviewer says they still stand."
  defp group_hint(:to_fix), do: "These go back to the engineer when you send them."
  defp group_hint(:fixed), do: "The reviewer checked these on the change as it now stands."
  defp group_hint(:dismissed), do: "You chose to live with these. The reviewer will not raise them again."

  defp severity_class(:blocker), do: "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300"
  defp severity_class(:major), do: "bg-orange-100 text-orange-700 dark:bg-orange-950 dark:text-orange-300"
  defp severity_class(:minor), do: "bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300"
  defp severity_class(:nit), do: "bg-slate-100 text-slate-600 dark:bg-slate-800 dark:text-slate-300"

  defp location(%ReviewFinding{file: file, line: nil}), do: file
  defp location(%ReviewFinding{file: file, line: line}), do: "#{file}:#{line}"

  defp toggle_label(:fix), do: "Don't fix"
  defp toggle_label(:skip), do: "Fix this"

  defp recommendation_line(%ReviewFinding{recommendation: :fix, decision: :skip}) do
    "The reviewer recommended fixing this. You dismissed it."
  end

  defp recommendation_line(%ReviewFinding{recommendation: :skip, decision: :fix}) do
    "The reviewer would have left this. You chose to fix it."
  end

  defp recommendation_line(%ReviewFinding{recommendation: :fix}), do: "The reviewer recommends fixing this."
  defp recommendation_line(%ReviewFinding{recommendation: :skip}), do: "The reviewer recommends leaving this."

  defp flip(:fix), do: :skip
  defp flip(:skip), do: :fix

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
  defp message_for(:no_engineer_role), do: "This project has no engineer to send the findings to."
  defp message_for(reason), do: "Could not finish that: #{inspect(reason)}"
end
