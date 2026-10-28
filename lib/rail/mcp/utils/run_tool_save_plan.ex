defmodule Rail.Mcp.Utils.RunToolSavePlan do
  @moduledoc """
  Saves the Plan agent's ticket and implementation plan, from the first draft to the last, with the design option
  the plan is written for.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @fields ["title", "description", "priority", "estimate", "plan", "design", "record_demo"]

  @again "Save again after every change; the human reads the last save."

  @doc """
  Saves the parts of the plan in `arguments` on `task` and says what is saved, or hands back the changeset that
  refused it.
  """
  def run_tool_save_plan(%Task{} = task, arguments, _opts) do
    issue = Repo.preload(task, :issue).issue

    case Pipeline.save_plan(task, Map.take(arguments, @fields)) do
      {:ok, %Round{} = round} ->
        said =
          Enum.filter(
            [
              not Issue.skips_step?(issue, :product) && "Ticket saved: #{round.ticket.title}.",
              not Issue.skips_step?(issue, :architect) &&
                cond do
                  round.plan == nil -> "No implementation plan is saved yet."
                  round.design != nil -> "Plan saved for #{round.design.title} (#{round.design.key})."
                  Issue.skips_step?(issue, :design) -> "Plan saved."
                  true -> "Plan saved, written for no design option yet."
                end
            ],
            &is_binary/1
          )

        {:ok, "#{if said == [], do: "Saved.", else: Enum.join(said, " ")} #{@again}"}

      {:error, :round_approved} ->
        {:refused, "Nothing saved: the plan is approved, so it no longer changes."}

      {:error, {:step_off, :product}} ->
        {:refused,
         "Nothing saved: Product is off for this task, so the issue is the ticket. Leave out `title`, `description`, `priority` and `estimate`."}

      {:error, {:step_off, :architect}} ->
        {:refused, "Nothing saved: Architect is off for this task, so it has no implementation plan. Leave out `plan`."}

      {:error, {:step_off, :demo}} ->
        {:refused, "Nothing saved: the demo is off for this task, so leave out `record_demo`."}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
