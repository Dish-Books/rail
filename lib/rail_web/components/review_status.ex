defmodule RailWeb.Components.ReviewStatus do
  @moduledoc """
  What the Findings item shows above the list while the Review run works or waits: a round running, a fix
  round, CI on the fix commit with the end of its log, the next round, CI failed three times, or nothing
  left to rule, with each agent at work and the work it was given.
  """
  use RailWeb, :html

  attr :phase, :atom, required: true, doc: "`:round`, `:fixing`, `:ci`, `:ci_failed` or `:finished`"
  attr :round, :integer, required: true, doc: "the round running, or the last one finished"
  attr :sha, :string, default: nil, doc: "the short commit CI or the round is on"
  attr :counts, :map, required: true, doc: "`%{fix:, fixed:, dismissed:}`"
  attr :agents, :list, default: [], doc: "`%{name:, work:, running:}` for each subagent of the turn"
  attr :tail, :list, default: [], doc: "the end of the CI log"
  attr :pr_number, :integer, default: nil

  def review_status(assigns) do
    assigns = assign(assigns, :said, said(assigns))

    ~H"""
    <div
      id="review-status"
      data-qa="review_status"
      data-phase={@phase}
      class="shrink-0 px-4 py-3 space-y-2 border-b border-slate-200 dark:border-slate-700"
    >
      <p class={["flex items-center gap-2 text-[13.5px] font-semibold", tone(@phase)]}>
        <span :if={@phase in [:round, :fixing, :ci]} class="relative flex size-2 shrink-0">
          <span class="absolute inline-flex size-full rounded-full bg-blue-400 opacity-75 motion-safe:animate-ping" />
          <span class="relative inline-flex size-2 rounded-full bg-blue-500" />
        </span>
        <.icon :if={@phase == :ci_failed} name="pi-warning-circle-fill" class="size-[15px]" />
        <.icon :if={@phase == :finished} name="pi-check-circle-fill" class="size-[15px]" />
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

      <div
        :if={@tail != [] and @phase in [:ci, :ci_failed]}
        data-qa="review_status_log"
        class="rounded-lg border border-slate-200 dark:border-slate-700 overflow-hidden"
      >
        <p class="flex items-center gap-2 px-3 py-1.5 border-b border-slate-200 dark:border-slate-700 bg-white dark:bg-slate-800/60 text-[11px] text-slate-500 dark:text-slate-400">
          <.icon name="pi-terminal-window" class="size-[13px]" />End of the CI log
        </p>
        <div class="overflow-x-auto bg-slate-50 dark:bg-slate-800/40 py-1.5 font-mono text-[11px] leading-[1.6]">
          <div
            :for={line <- @tail}
            class="pl-3 pr-4 whitespace-pre text-slate-700 dark:text-slate-300"
          >
            {line}
          </div>
        </div>
      </div>
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

  defp said(%{phase: :fixing} = assigns) do
    {"Fix round #{assigns.round} · Engineer fixing #{plural(assigns.counts.fix, "finding")}",
     "The code reviewer reads the fix diff before it is committed."}
  end

  defp said(%{phase: :ci} = assigns) do
    {"CI running#{on(assigns.sha)} · Fix round #{assigns.round}", "The next round starts on its own when CI passes."}
  end

  defp said(%{phase: :ci_failed} = assigns) do
    {"CI failed 3 times on fix round #{assigns.round}",
     "The Review lead stopped. Read the log, then message the lead or Retry."}
  end

  defp said(%{phase: :finished} = assigns) do
    pr = if assigns.pr_number, do: " PR ##{assigns.pr_number} is out of draft and ready to merge.", else: ""

    {"Nothing left to rule",
     "#{plural(assigns.counts.fixed, "finding")} fixed, #{assigns.counts.dismissed} not fixing.#{pr}"}
  end

  defp working(agents) do
    reviewers = Enum.count(agents, &(&1.running and &1.name == "Code reviewer"))
    explorers = Enum.count(agents, &(&1.running and String.starts_with?(&1.name, "QA explorer")))

    case {reviewers, explorers} do
      {0, 0} -> "Starting"
      {0, count} -> "#{plural(count, "QA explorer")} working"
      {_one, 0} -> "Code reviewer working"
      {_one, count} -> "Code reviewer and #{plural(count, "QA explorer")} working"
    end
  end

  defp of(nil), do: ""
  defp of(sha), do: " of #{sha}"

  defp on(nil), do: ""
  defp on(sha), do: " on #{sha}"

  defp plural(1, word), do: "1 #{word}"
  defp plural(count, word), do: "#{count} #{word}s"

  defp tone(phase) when phase in [:round, :fixing, :ci], do: "text-blue-600 dark:text-blue-400"
  defp tone(:ci_failed), do: "text-red-600 dark:text-red-400"
  defp tone(:finished), do: "text-emerald-600 dark:text-emerald-400"
end
