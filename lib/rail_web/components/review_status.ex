defmodule RailWeb.Components.ReviewStatus do
  @moduledoc """
  What the Findings item shows above the list while the Review run works or waits: a round running, a fix
  round's plan being written, waiting on approval or out of date, the fix round, CI on the fix commit, the next
  round, CI failed three times, or nothing left to rule, with each agent at work and the work it was given.
  """
  use RailWeb, :html

  attr :phase, :atom,
    required: true,
    doc: "`:round`, `:planning`, `:waiting`, `:outdated`, `:fixing`, `:ci`, `:ci_failed` or `:finished`"

  attr :round, :integer, required: true, doc: "the round running, or the last one finished"
  attr :sha, :string, default: nil, doc: "the short commit CI or the round is on"
  attr :counts, :map, required: true, doc: "`%{fix:, fixed:, dismissed:}`"
  attr :agents, :list, default: [], doc: "`%{name:, work:, running:}` for each subagent of the turn"
  attr :pr_number, :integer, default: nil
  attr :revising, :string, default: nil, doc: "what a plan being revised is revised on, as `1 changed ruling`"
  attr :target, :any, default: nil

  def review_status(assigns) do
    assigns = assign(assigns, :said, said(assigns))

    ~H"""
    <div
      id="review-status"
      data-qa="review_status"
      data-phase={@phase}
      class="shrink-0 px-4 py-3 border-b border-slate-200 dark:border-slate-700 flex items-center gap-4"
    >
      <div class="min-w-0 flex-1 space-y-2">
        <p class={[
          "flex flex-wrap items-center gap-x-2 gap-y-1 text-[13.5px] font-semibold",
          tone(@phase)
        ]}>
          <span
            :if={@phase in [:round, :planning, :fixing, :ci]}
            class="relative flex size-2 shrink-0"
          >
            <span class="absolute inline-flex size-full rounded-full bg-blue-400 opacity-75 motion-safe:animate-ping" />
            <span class="relative inline-flex size-2 rounded-full bg-blue-500" />
          </span>
          <.icon :if={@phase == :ci_failed} name="pi-warning-circle-fill" class="size-[15px]" />
          <.icon :if={@phase == :finished} name="pi-check-circle-fill" class="size-[15px]" />
          <.icon :if={@phase in [:waiting, :outdated]} name="pi-hand-palm-fill" class="size-[15px]" />
          <span data-qa="review_status_headline">{elem(@said, 0)}</span>
        </p>
        <p data-qa="review_status_body" class="text-[12.5px] text-slate-600 dark:text-slate-300">
          {elem(@said, 1)}
        </p>

        <div :if={@agents != []} class="flex flex-wrap gap-x-4 gap-y-1.5">
          <span
            :for={agent <- @agents}
            data-qa="review_status_agent"
            class="inline-flex items-center gap-1.5 min-w-0 text-[11.5px]"
          >
            <span :if={agent.running} class="relative flex size-2 shrink-0">
              <span class="absolute inline-flex size-full rounded-full bg-blue-400 opacity-75 motion-safe:animate-ping" />
              <span class="relative inline-flex size-2 rounded-full bg-blue-500" />
            </span>
            <.icon
              :if={!agent.running}
              name="pi-check-circle"
              class="size-[15px] text-emerald-600 dark:text-emerald-400"
            />
            <span class="shrink-0 font-semibold text-slate-800 dark:text-slate-100">{agent.name}</span>
            <span class="min-w-0 truncate text-slate-500 dark:text-slate-400">{agent.work}</span>
          </span>
        </div>
      </div>
      <button
        :if={@phase in [:waiting, :outdated]}
        type="button"
        id="review-status-open-fix-plan"
        phx-click="pick_item"
        phx-value-item="fix_plan"
        phx-target={@target}
        class="shrink-0 text-xs font-semibold text-blue-600 dark:text-blue-400 hover:underline cursor-pointer rounded focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
      >
        Open the fix plan
      </button>
    </div>
    """
  end

  defp said(%{phase: :round, round: 1} = assigns) do
    {"Round 1 · #{working(assigns.agents)}",
     "Nothing to rule until the code reviewer and every explorer finish. Findings appear as they are saved."}
  end

  defp said(%{phase: :round} = assigns) do
    {"Round #{assigns.round} · Re-review#{of(assigns.sha)}",
     "Against the #{plural(assigns.counts.fix + assigns.counts.fixed, "finding")} ruled Fix and their rules."}
  end

  defp said(%{phase: :planning, revising: nil} = assigns),
    do:
      {"Fix round #{assigns.round} · Review lead writing the fix plan",
       "Nothing changes until you approve it. Approve appears in the header once the plan is saved."}

  defp said(%{phase: :planning} = assigns),
    do:
      {"Fix round #{assigns.round} · Review lead writing the fix plan",
       "On #{assigns.revising}. Approve comes back when the revised plan is saved."}

  defp said(%{phase: :waiting} = assigns),
    do:
      {"Fix round #{assigns.round} · Fix plan waiting on your approval",
       "Nothing changes until you approve. Changed rulings and comments you send, or a message to the lead, get a revised plan in its place."}

  defp said(%{phase: :outdated} = assigns),
    do:
      {"Fix round #{assigns.round} · Fix plan out of date",
       "A ruling changed since the plan was saved. Send the change from the tray for a revised plan, or change it back to approve this one."}

  # A Send of comments alone, or a chat turn on a finished review, has the lead at work with nothing ruled Fix.
  defp said(%{phase: :fixing, counts: %{fix: 0}}),
    do: {"Review lead working on what was sent", "Nothing is ruled Fix, so no finding is being fixed."}

  defp said(%{phase: :fixing} = assigns) do
    {"Fix round #{assigns.round} · Engineer fixing #{plural(assigns.counts.fix, "finding")}",
     "The code reviewer reads the fix diff before it is committed."}
  end

  defp said(%{phase: :ci} = assigns) do
    {"CI running#{on(assigns.sha)} · Fix round #{assigns.round}", "The next round starts on its own when CI passes."}
  end

  defp said(%{phase: :ci_failed} = assigns) do
    {"CI failed 3 times on fix round #{assigns.round}",
     "The Review lead stopped. Read the CI output in the conversation, then message the lead. It can run CI again with nothing changed."}
  end

  defp said(%{phase: :finished} = assigns) do
    pr = if assigns.pr_number, do: " PR ##{assigns.pr_number} is out of draft and ready to merge.", else: ""

    {"Nothing left to rule",
     "#{plural(assigns.counts.fixed, "finding")} fixed, #{assigns.counts.dismissed} not fixing.#{pr}"}
  end

  defp working(agents) do
    case for(%{running: true, name: name} <- agents, do: name) do
      [] -> "Starting"
      [one] -> "#{one} working"
      names -> Enum.join(Enum.drop(names, -1), ", ") <> " and #{List.last(names)} working"
    end
  end

  defp of(nil), do: ""
  defp of(sha), do: " of #{sha}"

  defp on(nil), do: ""
  defp on(sha), do: " on #{sha}"

  defp plural(1, word), do: "1 #{word}"
  defp plural(count, word), do: "#{count} #{word}s"

  defp tone(phase) when phase in [:round, :planning, :fixing, :ci], do: "text-blue-600 dark:text-blue-400"
  defp tone(phase) when phase in [:waiting, :outdated], do: "text-amber-600 dark:text-amber-400"
  defp tone(:ci_failed), do: "text-red-600 dark:text-red-400"
  defp tone(:finished), do: "text-emerald-600 dark:text-emerald-400"
end
