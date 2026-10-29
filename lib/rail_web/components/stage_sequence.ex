defmodule RailWeb.Components.StageSequence do
  @moduledoc """
  The stages a workflow's task runs, in order, such as "Plan › Implement › License check › Review", with the steps it
  skips. A custom stage reads by its name, set apart from the built-ins.
  """
  use RailWeb, :html

  alias Rail.Issues.Schemas.Issue

  @plan_steps [:product, :design, :architect]

  attr :id, :string, required: true
  attr :skipped, :list, required: true, doc: "the steps the workflow turned off, from `Issue.optional_steps/0`"
  attr :stages, :list, default: [], doc: "the `IssueStage`s the workflow named, or none for the built-ins"
  attr :layout, :atom, values: [:stacked, :inline], default: :stacked, doc: "two lines, or one run on after a dot"

  def stage_sequence(assigns) do
    stages = Issue.calculate_stages(%Issue{skipped_steps: assigns.skipped, stages: assigns.stages})

    assigns =
      assigns
      |> assign(:sequence, Enum.with_index(stages))
      |> assign(:skips, skips(assigns.skipped))

    ~H"""
    <span :if={@layout == :stacked} id={@id} data-qa="stage-sequence" class="block">
      <span id={"#{@id}-stages"} class="block text-slate-700 dark:text-slate-300"><.stages sequence={
        @sequence
      } /></span>
      <span :if={@skips} id={"#{@id}-skips"} class="block text-xs text-slate-500 dark:text-slate-400">
        Skips {@skips}
      </span>
    </span>
    <span :if={@layout == :inline} id={@id} data-qa="stage-sequence">
      ·
      <span id={"#{@id}-stages"}><.stages sequence={@sequence} /></span><span
        :if={@skips}
        id={"#{@id}-skips"}
      > · skips {@skips}</span>
    </span>
    """
  end

  attr :sequence, :list, required: true

  defp stages(assigns) do
    ~H"""
    <span :for={{stage, index} <- @sequence}>{if index > 0, do: " › "}<span
      :if={match?({:custom, _name}, stage)}
      class="font-semibold text-slate-900 dark:text-slate-100"
    >{stage_label(stage)}</span>{if !match?({:custom, _name}, stage), do: stage_label(stage)}</span>
    """
  end

  defp stage_label({:custom, name}), do: name
  defp stage_label(:plan), do: "Plan"
  defp stage_label(:engineer), do: "Implement"
  defp stage_label(:review), do: "Review"

  # All three Plan steps off is no Plan at all, so it reads as one word.
  defp skips(skipped) do
    words =
      if Enum.all?(@plan_steps, &(&1 in skipped)),
        do: ["plan" | if(:demo in skipped, do: ["demo"], else: [])],
        else: for(step <- Issue.optional_steps(), step in skipped, do: Issue.step_label(step))

    case words do
      [] -> nil
      [one] -> one
      _several -> Enum.join(Enum.drop(words, -1), ", ") <> " and " <> List.last(words)
    end
  end
end
