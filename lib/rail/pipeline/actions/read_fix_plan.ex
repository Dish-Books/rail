defmodule Rail.Pipeline.Actions.ReadFixPlan do
  @moduledoc """
  Reads the fix plan of a task's latest fix round from `<scratch>/fix_plans/<identifier>.json`. Only Rail writes
  it, so it is read as it stands.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns `task`'s fix plan, or `nil` when no Send has started one. Requires `issue` to be preloaded.
  """
  def read_fix_plan(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    case File.read(Path.join([scratch_path, "fix_plans", "#{identifier}.json"])) do
      {:ok, content} ->
        %FixPlan{} |> FixPlan.changeset(Jason.decode!(content)) |> Ecto.Changeset.apply_changes()

      {:error, :enoent} ->
        nil
    end
  end
end
