defmodule Rail.Pipeline.Actions.SaveFixPlan do
  @moduledoc """
  Saves the Review lead's plan for the fix round a Send started, in place of the one before it. A plan is due only
  while the round's fix plan is unapproved, so the first round, a CI resume and an approved round take none.
  """

  import Ecto.Changeset
  import Rail.Pipeline.Utils.WriteFixPlan

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Saves `attrs["plan"]` as the next version of `task`'s fix plan. Returns `{:ok, fix_plan}`, `{:error, :no_fix_plan}`
  when none is due, or `{:error, changeset}` naming what to fix.
  """
  def save_fix_plan(%Task{} = task, attrs) when is_map(attrs) do
    task = Repo.preload(task, :issue)

    with %FixPlan{approved_at: nil} = fix_plan <- Pipeline.read_fix_plan(task),
         {:ok, saved} <- fix_plan |> FixPlan.save_changeset(attrs) |> apply_action(:update) do
      write_fix_plan(task, saved)
      Pipeline.broadcast_output_saved(task)
      {:ok, saved}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      _none_due -> {:error, :no_fix_plan}
    end
  end
end
