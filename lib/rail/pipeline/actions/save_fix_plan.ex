defmodule Rail.Pipeline.Actions.SaveFixPlan do
  @moduledoc """
  Saves the review agent's plan for the next round, in place of the one before it. A plan is due once a review is
  saved, until the task merges, or while one a Send asked for waits. A plan with nothing to fix, no comment to
  answer and no change to the ticket or the design is no round at all, so it is refused rather than left waiting
  on an approval that would start an engineer on nothing, while it holds back Finish review.
  """

  import Ecto.Changeset
  import Rail.Pipeline.Utils.WriteFixPlan

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Saves `attrs["plan"]` as the next version of `task`'s fix plan. Returns `{:ok, fix_plan}`, `{:error, :no_fix_plan}`
  when none is due, `{:error, :nothing_to_fix}` for a plan that changes nothing, `{:error, {:step_off, :demo}}` for a
  demo asked of a task whose workflow turned it off, or `{:error, changeset}` naming what to fix.
  """
  def save_fix_plan(%Task{} = task, attrs) when is_map(attrs) do
    task = Repo.preload(task, :issue)

    with false <- Issue.skips_step?(task.issue, :demo) and attrs["record_demo"] == true,
         %FixPlan{} = fix_plan <- due(task),
         :ok <- something(fix_plan, attrs),
         {:ok, saved} <- fix_plan |> FixPlan.save_changeset(attrs) |> apply_action(:update) do
      write_fix_plan(task, saved)
      Pipeline.broadcast_output_saved(task)
      {:ok, saved}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, :nothing_to_fix} -> {:error, :nothing_to_fix}
      true -> {:error, {:step_off, :demo}}
      _none_due -> {:error, :no_fix_plan}
    end
  end

  defp something(%FixPlan{findings: [], comments: []}, attrs) do
    if Enum.any?(["title", "description", "design_changed"], &(attrs[&1] not in [nil, false, ""])),
      do: :ok,
      else: {:error, :nothing_to_fix}
  end

  defp something(%FixPlan{}, _attrs), do: :ok

  # A plan a Send asked for waits to be saved. With none waiting, the review agent writes the next round's
  # unasked once a review is saved: it covers every finding to fix as they stand now, and a change to the ticket or
  # the design a person asked for, which can come with no finding at all.
  defp due(%Task{stage: stage} = task) do
    passes = Pipeline.read_review(task)

    case Pipeline.read_fix_plan(task) do
      %FixPlan{approved_at: nil} = waiting ->
        waiting

      _none_or_approved when stage in [:review, :finalize] and passes != [] ->
        fix = task |> Pipeline.list_findings() |> Enum.filter(&Finding.outstanding?/1)

        %FixPlan{
          round: length(passes),
          head: List.last(passes).head,
          findings: Enum.map(fix, &%FixPlan.Finding{key: &1.key, title: &1.title})
        }

      _none_due ->
        nil
    end
  end
end
