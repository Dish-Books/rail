defmodule Rail.Pipeline.Actions.SaveFixPlan do
  @moduledoc """
  Saves the review agent's plan for the next round, in place of the one before it. A plan is due once a review is
  saved, until the task merges, or while one a Send asked for waits.
  """

  import Ecto.Changeset
  import Rail.Pipeline.Utils.WriteFixPlan

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Saves `attrs["plan"]` as the next version of `task`'s fix plan. Returns `{:ok, fix_plan}`, `{:error, :no_fix_plan}`
  when none is due, or `{:error, changeset}` naming what to fix.
  """
  def save_fix_plan(%Task{} = task, attrs) when is_map(attrs) do
    task = Repo.preload(task, :issue)

    with %FixPlan{} = fix_plan <- due(task),
         {:ok, saved} <- fix_plan |> FixPlan.save_changeset(attrs) |> apply_action(:update) do
      write_fix_plan(task, saved)
      Pipeline.broadcast_output_saved(task)
      {:ok, saved}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      _none_due -> {:error, :no_fix_plan}
    end
  end

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
