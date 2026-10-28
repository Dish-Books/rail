defmodule RailWeb.Components.UpNext do
  @moduledoc """
  The runs waiting on a human, longest-waiting first.

  The first leads as a card and the rest follow as rows. Nothing here acts on a
  run: what the human does next — reading a ticket, answering a question — needs
  the task in front of them, so every entry is only a way there. A task whose
  review finished and that nobody has marked ready is a Finalize row, opening on
  Finalize, unless its fix round's plan waits on approval, which opens the plan.
  """
  use RailWeb, :html

  import RailWeb.Utils.StageLabel

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role

  attr :runs, :list, required: true
  # Children of a split a canceled or deleted sibling keeps from starting: `%{status:, parent:}`, a
  # `RailWeb.Utils.ChildStatus` map and the split's parent. They have no run, so they come apart.
  attr :blocked, :list, default: []

  def up_next(assigns) do
    # Read once per render: whether a Plan run waits on a pick is a file on disk, not a field.
    picking =
      for %Run{task: %Task{stage: :plan} = task} = run <- assigns.runs,
          Run.state(run) == :done and waiting_on_pick?(task),
          into: MapSet.new(),
          do: run.id

    # Read once per render too: a fix round's plan waiting on approval is a file on disk.
    fix_plans =
      for %Run{role: %Role{stage: :review_lead}, task: %Task{stage: stage} = task} = run <- assigns.runs,
          stage in [:review, :finalize] and Run.state(run) == :done and fix_plan_waiting?(task),
          into: MapSet.new(),
          do: run.id

    # Marking ready is one click, not something to read, so it is never the card that leads.
    featured = Enum.find(assigns.runs, &(not finalizing?(&1) or MapSet.member?(fix_plans, &1.id)))

    assigns =
      assigns
      |> assign(:featured, featured)
      |> assign(:rest, List.delete(assigns.runs, featured))
      |> assign(:picking, picking)
      |> assign(:fix_plans, fix_plans)
      |> assign(:featured_icon, featured_icon(featured, fix_plans))

    ~H"""
    <div id="up-next" data-qa="up-next" class="space-y-3">
      <p
        :if={@runs == [] and @blocked == []}
        id="up-next-empty"
        class="rounded-xl border border-dashed border-slate-300 dark:border-slate-700 px-5 py-6 text-sm text-center text-slate-500 dark:text-slate-400"
      >
        Nothing is waiting on you.
      </p>

      <.link
        :if={@featured}
        {destination(@featured, @fix_plans)}
        id={"up-next-featured-#{@featured.id}"}
        data-qa="up-next-featured"
        class="@container group block rounded-xl border border-amber-300 dark:border-amber-800/70 bg-amber-50 dark:bg-amber-950/30 px-5 py-4 transition-colors hover:bg-amber-100/70 dark:hover:bg-amber-950/50"
      >
        <div class="flex flex-col gap-4 @lg:flex-row @lg:items-center">
          <div class="min-w-0 flex-1">
            <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
              <span
                data-qa="up-next-chip"
                class={[
                  "inline-flex items-center whitespace-nowrap px-2 py-0.5 rounded text-[11px] font-bold uppercase tracking-wider",
                  tone(@featured).chip
                ]}
              >
                <.icon :if={@featured_icon} name={@featured_icon} class="size-3 -ml-0.5 mr-1" />{chip(
                  @featured
                )}
              </span>
              <span class="font-mono text-xs text-slate-600 dark:text-slate-400 truncate">
                {@featured.task.issue.identifier} · {Task.stage_label(@featured.task)}
                <span :if={parent_identifier(@featured)} class="text-slate-500 dark:text-slate-400">
                  in {parent_identifier(@featured)}
                </span>
              </span>
            </div>

            <h3 class="mt-2 text-lg font-semibold leading-snug text-slate-900 dark:text-slate-100">
              {@featured.task.issue.title}
            </h3>

            <p data-qa="up-next-summary" class="mt-1 text-sm text-slate-600 dark:text-slate-400">
              {summary(@featured, @picking, @fix_plans)}
            </p>
          </div>

          <span
            data-qa="up-next-action"
            class={[
              "self-start @lg:self-center shrink-0 inline-flex items-center px-4 py-2 rounded-lg text-sm font-semibold transition-colors",
              tone(@featured).action
            ]}
          >
            <.icon :if={@featured_icon} name={@featured_icon} class="size-[15px] mr-1.5" />{verb(
              @featured,
              @picking,
              @fix_plans
            )}
          </span>
        </div>
      </.link>

      <.link
        :for={run <- @rest}
        {destination(run, @fix_plans)}
        id={if finalizing?(run), do: "up-next-finalize-row-#{run.id}", else: "up-next-row-#{run.id}"}
        data-qa="up-next-row"
        class="group flex items-center gap-4 rounded-xl border border-slate-200 dark:border-slate-700/70 bg-white dark:bg-slate-800/40 px-5 py-3.5 transition-colors hover:bg-slate-50 dark:hover:bg-slate-800/70"
      >
        <span class="font-mono text-xs text-slate-500 dark:text-slate-400 shrink-0 w-16">
          {run.task.issue.identifier}
        </span>
        <span class="min-w-0 flex-1 truncate text-sm text-slate-900 dark:text-slate-100">
          {run.task.issue.title} ·
          <span class="text-slate-500 dark:text-slate-400">{detail(run, @picking, @fix_plans)}</span>
        </span>
        <span
          :if={parent_identifier(run)}
          data-qa="up-next-parent"
          class="shrink-0 font-mono text-xs text-slate-500 dark:text-slate-400"
        >
          in {parent_identifier(run)}
        </span>
        <span class="shrink-0 text-sm font-semibold text-blue-600 dark:text-blue-400 group-hover:underline">
          {verb(run, @picking, @fix_plans)}
        </span>
      </.link>

      <.link
        :for={%{status: status, parent: parent} <- @blocked}
        navigate={~p"/tasks/#{parent.id}?child=#{status.identifier}"}
        id={"up-next-blocked-#{status.task.id}"}
        data-qa="up-next-row"
        class="group flex items-center gap-4 rounded-xl border border-slate-200 dark:border-slate-700/70 bg-white dark:bg-slate-800/40 px-5 py-3.5 transition-colors hover:bg-slate-50 dark:hover:bg-slate-800/70"
      >
        <span class="font-mono text-xs text-slate-500 dark:text-slate-400 shrink-0 w-16">
          {status.identifier}
        </span>
        <span class="min-w-0 flex-1 truncate text-sm text-slate-900 dark:text-slate-100">
          {status.task.issue.title} ·
          <span class="text-amber-700 dark:text-amber-300">{status.line}</span>
        </span>
        <span class="shrink-0 font-mono text-xs text-slate-500 dark:text-slate-400">
          in {parent.issue.identifier}
        </span>
        <span class="shrink-0 text-sm font-semibold text-blue-600 dark:text-blue-400 group-hover:underline">
          Open
        </span>
      </.link>
    </div>
    """
  end

  # A child of a split is named with its parent, which is what the person planned.
  defp parent_identifier(%Run{task: %Task{parent_task: %Task{issue: %{identifier: identifier}}}}), do: identifier
  defp parent_identifier(%Run{}), do: nil

  # Review is what the merge is decided on, so a change ready for it opens on its findings, and one at Finalize on
  # the task, whose header merges it. A question is answered in its agent's conversation, beside the plan, which the
  # task opens on by itself only for the agent taking messages: Plan at Plan, a custom stage at its own, the review
  # agent after.
  defp destination(run, fix_plans) do
    cond do
      MapSet.member?(fix_plans, run.id) ->
        [navigate: ~p"/tasks/#{run.task_id}?item=fix_plan"]

      finalizing?(run) ->
        [navigate: ~p"/tasks/#{run.task_id}"]

      ready_to_merge?(run) ->
        [navigate: ~p"/tasks/#{run.task_id}?item=findings"]

      Run.state(run) == :blocked and not chat_run?(run) ->
        [navigate: ~p"/tasks/#{run.task_id}?item=plan&agent=#{run.role.stage}"]

      true ->
        [navigate: ~p"/tasks/#{run.task_id}"]
    end
  end

  defp chat_run?(%Run{role: %Role{custom_stage: name}, task: %Task{} = task} = run) when is_binary(name),
    do: Task.works_stage?(task, run.role)

  defp chat_run?(%Run{role: %Role{stage: stage}, task: %Task{stage: :plan}}), do: stage == :plan
  defp chat_run?(%Run{role: %Role{stage: stage}}), do: stage == :review_lead

  # The Review run of a task at Finalize waits only on someone marking it ready.
  defp finalizing?(%Run{task: %Task{stage: :finalize}} = run), do: Run.state(run) == :done
  defp finalizing?(%Run{}), do: false

  # A Review round or fix plan waiting on a person carries the Review screen's Findings icon; every other card is words alone.
  defp featured_icon(%Run{task: %Task{} = task} = run, fix_plans) do
    cond do
      review_waiting?(task, run) -> run_state_style(run, task).icon
      MapSet.member?(fix_plans, run.id) -> "pi-list-checks"
      true -> nil
    end
  end

  defp featured_icon(nil, _fix_plans), do: nil

  # A finished Review with a pull request to merge has nothing left to wait on but the merge.
  defp ready_to_merge?(%Run{role: %Role{stage: :review_lead}, task: %Task{pr_url: pr_url} = task} = run)
       when is_binary(pr_url) do
    ready_to_merge?(task, run)
  end

  defp ready_to_merge?(%Run{}), do: false

  # Three things bring a run here, and they are not the same errand. A done run has
  # produced the work of its stage and waits on that being read. A blocked run
  # waits on its questions. A run that failed or stopped waits on someone picking
  # it up, and says nothing about itself until they do.
  defp chip(run) do
    case Run.state(run) do
      :done -> if ready_to_merge?(run), do: "Ready to merge", else: "Ready for review"
      :blocked -> "Needs an answer"
      _stalled -> "Needs a fix"
    end
  end

  defp verb(run, picking, fix_plans) do
    case Run.state(run) do
      :done ->
        cond do
          MapSet.member?(fix_plans, run.id) -> "Review"
          finalizing?(run) -> "Finalize"
          ready_to_merge?(run) -> "Ready to merge"
          MapSet.member?(picking, run.id) -> "Pick"
          true -> "Review"
        end

      :blocked ->
        "Answer"

      _stalled ->
        "Fix"
    end
  end

  defp summary(run, picking, fix_plans) do
    case Run.state(run) do
      :done ->
        cond do
          MapSet.member?(fix_plans, run.id) -> "Waiting on you to approve the fix plan."
          ready_to_merge?(run) -> "The review is finished, and the pull request is waiting on you to merge it."
          MapSet.member?(picking, run.id) -> "Waiting on you to pick a design."
          true -> "Waiting on you to read the #{work(run)}."
        end

      :blocked ->
        asked(run)

      _stalled ->
        stalled(run)
    end
  end

  defp detail(run, picking, fix_plans) do
    case Run.state(run) do
      :done ->
        cond do
          MapSet.member?(fix_plans, run.id) -> "fix plan to approve"
          finalizing?(run) or ready_to_merge?(run) -> "review finished"
          MapSet.member?(picking, run.id) -> "pick a design"
          true -> "#{work(run)} ready for review"
        end

      :blocked ->
        "#{run.role.name} asked #{questions(run)}"

      _stalled ->
        stalled(run)
    end
  end

  # A round with nothing answered has nothing to send; the task page closes it instead.
  defp asked(run) do
    unsent = Enum.filter(run.questions, &(&1.delivered_at == nil))

    case Enum.find(run.questions, &(&1.status == :pending)) do
      %Question{prompt: prompt} ->
        prompt

      nil ->
        if unsent != [] and Enum.all?(unsent, &(&1.status == :dismissed)),
          do: "Every question is dismissed. Close the round from the task.",
          else: "Every question is answered and ready to send."
    end
  end

  # What a failed run left behind is the error; a stopped one left nothing, and
  # what it needs is the same either way.
  defp stalled(%Run{error: error}) when is_binary(error), do: error

  # With no conversation to resume, Retry is the only way on.
  defp stalled(%Run{} = run) do
    if Run.resumable?(run),
      do: "#{run.role.name} stopped before finishing. Send it a message to pick up where it left off.",
      else: "#{run.role.name} stopped before finishing. Retry it to start again from its brief."
  end

  # A stage that stalled is a problem rather than a queue, and reads as one.
  defp tone(run) do
    if Run.state(run) in [:failed, :stopped] do
      %{chip: "bg-red-500 text-white", action: "bg-red-500 text-slate-950 group-hover:bg-red-400"}
    else
      %{chip: "bg-amber-500 text-slate-950", action: "bg-amber-500 text-slate-950 group-hover:bg-amber-400"}
    end
  end

  defp work(%Run{task: %Task{stage: :plan}}), do: "plan"
  defp work(%Run{task: %Task{stage: :engineer}}), do: "diff"
  defp work(%Run{task: %Task{stage: :review}}), do: "findings"

  defp questions(%Run{questions: [_one]}), do: "a question"
  defp questions(%Run{questions: questions}), do: "#{length(questions)} questions"
end
