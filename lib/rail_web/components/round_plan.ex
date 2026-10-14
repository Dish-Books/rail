defmodule RailWeb.Components.RoundPlan do
  @moduledoc """
  A later round's plan as it was approved: who approved it and when, the changes it made to the ticket or the
  first plan called out above everything else, since those are what a reader checks first, then the plan.
  """
  use RailWeb, :html

  alias Rail.Pipeline.Schemas.Round

  attr :round, :any, required: true, doc: "the `Round` picked, or nil when the round has no plan of its own"

  def round_plan(assigns) do
    {changes, plan} = split_changes(assigns.round)
    assigns = assigns |> assign(:changes, changes) |> assign(:plan, plan)

    ~H"""
    <div id="round-plan" data-qa="round_plan" class="flex-1 min-h-0 overflow-y-auto px-6 py-6">
      <p :if={@plan == nil} id="round-plan-none" class="text-sm text-slate-500 dark:text-slate-400">
        This round has no plan of its own.
      </p>

      <div :if={@plan != nil} class="max-w-3xl space-y-5">
        <p
          id="round-plan-approved"
          class="flex items-center gap-1.5 text-xs text-slate-500 dark:text-slate-400"
        >
          <.icon name="pi-check-circle" class="size-3.5 text-emerald-600 dark:text-emerald-400" />
          Round {@round.number}
          <span :if={@round.approved_at}>
            · approved <.local_time id="round-plan-approved-at" at={@round.approved_at} />
          </span>
        </p>

        <aside
          :if={@changes}
          id="round-plan-changes"
          data-qa="round_plan_changes"
          class="rounded-xl border border-amber-200 dark:border-amber-900 bg-amber-50 dark:bg-amber-950 px-4 py-3"
        >
          <h3 class="flex items-center gap-1.5 text-sm font-semibold text-amber-900 dark:text-amber-200">
            <.icon name="pi-pencil-simple-line" class="size-4" /> Changes to the plan
          </h3>
          <.markdown content={@changes} class="mt-2" />
        </aside>

        <div id="round-plan-body"><.markdown content={@plan} /></div>
      </div>
    </div>
    """
  end

  # The section a plan that changes the ticket opens with, apart from the rest of the plan.
  defp split_changes(%Round{plan: plan}) when is_binary(plan) do
    case Regex.run(~r/\A(.*?)### Changes to the plan\n(.*?)(?=^### |\z)(.*)\z/ms, plan) do
      [_whole, before, changes, rest] -> {String.trim(changes), String.trim(before <> rest)}
      nil -> {nil, plan}
    end
  end

  defp split_changes(_none), do: {nil, nil}
end
