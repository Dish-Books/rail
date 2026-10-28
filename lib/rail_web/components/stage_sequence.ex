defmodule RailWeb.Components.StageSequence do
  @moduledoc """
  The stages a workflow's task runs, in order, such as "Plan › Implement › Review", with the steps it skips.
  """
  use RailWeb, :html

  alias Rail.Issues.Schemas.Issue

  @plan_steps [:product, :design, :architect]

  attr :id, :string, required: true
  attr :skipped, :list, required: true, doc: "the steps the workflow turned off, from `Issue.optional_steps/0`"
  attr :layout, :atom, values: [:stacked, :inline], default: :stacked, doc: "two lines, or one run on after a dot"

  def stage_sequence(assigns) do
    stages = Issue.calculate_stages(%Issue{skipped_steps: assigns.skipped})

    assigns =
      assigns
      |> assign(:stages, Enum.map_join(stages, " › ", &stage_label/1))
      |> assign(:skips, skips(assigns.skipped))

    ~H"""
    <span :if={@layout == :stacked} id={@id} data-qa="stage-sequence" class="block">
      <span id={"#{@id}-stages"} class="block text-slate-700 dark:text-slate-300">{@stages}</span>
      <span :if={@skips} id={"#{@id}-skips"} class="block text-xs text-slate-500 dark:text-slate-400">
        Skips {@skips}
      </span>
    </span>
    <span :if={@layout == :inline} id={@id} data-qa="stage-sequence">
      ·
      <span id={"#{@id}-stages"}>{@stages}</span><span :if={@skips} id={"#{@id}-skips"}> · skips {@skips}</span>
    </span>
    """
  end

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
