defmodule RailWeb.Components.FindingList do
  @moduledoc """
  Review's findings down the side, grouped by the round that raised them, newest first, with a Fix finding
  a later round found still failing under Carried into round N. Each row is its title, where it stands and
  where it is. The footer's tally is the Findings item's state, beside Start fix round or Finish review.
  """
  use RailWeb, :html

  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingNote

  attr :findings, :list, required: true, doc: "in `Rail.Pipeline.list_findings/1`'s order"
  attr :selected_key, :string, default: nil
  attr :running, :boolean, required: true
  attr :tally, :string, required: true
  attr :button, :map, default: nil, doc: "`%{label:, icon:, disabled:, title:}`, or nil for none"
  attr :target, :any, required: true

  def finding_list(assigns) do
    assigns = assign(assigns, :groups, groups(assigns.findings))

    ~H"""
    <div
      id="review-finding-list"
      data-qa="review_finding_list"
      class="w-full @2xl:w-[260px] @4xl:w-[300px] max-h-[40%] @2xl:max-h-none shrink-0 flex flex-col min-h-0 border-b @2xl:border-b-0 @2xl:border-r border-slate-200 dark:border-slate-700"
    >
      <div class="flex items-baseline gap-2 px-4 py-3 border-b border-slate-200 dark:border-slate-700">
        <span class="text-sm font-bold text-slate-900 dark:text-slate-100">Findings</span>
        <span class="text-xs text-slate-500 dark:text-slate-400">{length(@findings)}</span>
      </div>

      <div class="flex-1 min-h-0 overflow-y-auto p-2 space-y-1">
        <div :for={{heading, findings} <- @groups} data-qa="review_finding_group" class="space-y-1">
          <p class="px-3 pt-2.5 pb-1 text-[10.5px] font-extrabold uppercase tracking-[0.14em] text-slate-400 dark:text-slate-500">
            {heading}
          </p>
          <button
            :for={finding <- findings}
            type="button"
            id={"finding-#{finding.key}"}
            data-qa="review_finding"
            data-state={Finding.state(finding)}
            phx-hook="CurrentInView"
            phx-click="select_finding"
            phx-target={@target}
            phx-value-key={finding.key}
            aria-current={to_string(@selected_key == finding.key)}
            class={[
              "w-full flex gap-2.5 px-3 py-2.5 rounded-lg text-left cursor-pointer focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500",
              @selected_key == finding.key &&
                "bg-blue-50 dark:bg-blue-950/40 ring-1 ring-blue-300 dark:ring-blue-800",
              @selected_key != finding.key && "hover:bg-slate-100 dark:hover:bg-slate-800/60",
              Finding.state(finding) == :dismissed && "opacity-60"
            ]}
          >
            <span class={["mt-1.5 size-1.5 shrink-0 rounded-full", dot(finding)]} />
            <span class="min-w-0 flex-1">
              <span class={[
                "block text-[13px] leading-snug wrap-anywhere",
                @selected_key == finding.key && "font-semibold text-slate-900 dark:text-slate-100",
                @selected_key != finding.key && "text-slate-700 dark:text-slate-300",
                Finding.state(finding) == :dismissed && "line-through"
              ]}>
                {finding.title}
              </span>
              <span :if={state_line(finding, @running)} class="block">
                <span
                  data-qa="review_finding_state"
                  class={["text-[10px] font-semibold", state_class(finding)]}
                >
                  {state_line(finding, @running)}
                </span>
              </span>
              <span :if={Finding.where(finding)} class="flex items-center gap-1 min-w-0">
                <.icon
                  name={if finding.kind == :screen, do: "pi-browser", else: "pi-code"}
                  class="size-[11px] text-slate-400 dark:text-slate-500"
                />
                <span class={[
                  "truncate text-[10px] text-slate-500 dark:text-slate-400",
                  finding.kind == :code && "font-mono"
                ]}>
                  {Finding.where(finding)}
                </span>
              </span>
            </span>
          </button>
        </div>
      </div>

      <div
        id="review-finding-footer"
        data-qa="review_finding_footer"
        class="flex flex-wrap items-center gap-x-3 gap-y-2 px-4 py-2.5 border-t border-slate-200 dark:border-slate-700"
      >
        <p
          data-qa="review_finding_tally"
          class="min-w-0 flex-1 basis-40 text-xs text-slate-500 dark:text-slate-400"
        >
          {@tally}
        </p>
        <button
          :if={@button}
          type="button"
          id="start-fix-round"
          data-qa="start_fix_round"
          phx-click="start_fix_round"
          phx-target={@target}
          phx-disable-with={@button.label}
          disabled={@button.disabled}
          title={@button.title}
          class="shrink-0 inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-semibold bg-blue-600 dark:bg-blue-500 text-white hover:opacity-90 cursor-pointer shadow-xs disabled:opacity-50 disabled:cursor-not-allowed focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-500"
        >
          <.icon name={@button.icon} class="size-3.5" />{@button.label}
        </button>
      </div>
    </div>
    """
  end

  # The list is already in group order, so a group is a run of findings sharing a heading.
  defp groups(findings) do
    findings
    |> Enum.chunk_by(&heading/1)
    |> Enum.map(&{heading(hd(&1)), &1})
  end

  defp heading(%Finding{carried_round: round}) when is_integer(round), do: "Carried into round #{round}"
  defp heading(%Finding{round: round}), do: "Round #{round}"

  # A pass still going is not one to rule on, so nothing asks for a call until it has finished.
  defp state_line(%Finding{} = finding, running) do
    case Finding.state(finding) do
      :undecided -> if not running, do: "Needs your call"
      :to_fix -> "Fix"
      :not_fixed -> "Fix · still failing" <> on(still_failing_on(finding))
      :fixed -> if finding.fixed_in, do: "Fixed in #{short(finding.fixed_in)}", else: "Fixed"
      :dismissed -> "Don't fix"
      :suppressed -> "Suppressed"
    end
  end

  defp on(nil), do: ""
  defp on(commit), do: " on #{short(commit)}"

  # The commit the last pass saw it still failing on.
  defp still_failing_on(%Finding{notes: notes}) do
    notes |> Enum.reverse() |> Enum.find_value(fn %FindingNote{} = note -> note.status == :not_fixed && note.commit end)
  end

  defp short(commit), do: String.slice(commit, 0, 7)

  defp state_class(%Finding{} = finding) do
    case Finding.state(finding) do
      :undecided -> "text-blue-600 dark:text-blue-400"
      :not_fixed -> "text-red-600 dark:text-red-400"
      :fixed -> "text-emerald-600 dark:text-emerald-500"
      _ruled -> "text-slate-500 dark:text-slate-400"
    end
  end

  # A settled finding is not asking for attention, so it stops shouting whatever it was raised as.
  defp dot(%Finding{} = finding) do
    case {Finding.state(finding), finding.severity} do
      {:fixed, _severity} -> "bg-emerald-500"
      {state, _severity} when state in [:dismissed, :suppressed] -> "bg-slate-300 dark:bg-slate-600"
      {_state, :blocker} -> "bg-red-500"
      {_state, :major} -> "bg-amber-500"
      {_state, :minor} -> "bg-amber-400"
      {_state, :nit} -> "bg-slate-400"
    end
  end
end
