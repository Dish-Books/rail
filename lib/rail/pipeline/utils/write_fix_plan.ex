defmodule Rail.Pipeline.Utils.WriteFixPlan do
  @moduledoc false

  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Writes `fix_plan`, as `read_fix_plan/1` reads it, as `task`'s fix plan file. Requires `issue` loaded.
  """
  def write_fix_plan(%Task{issue: %Issue{identifier: identifier}} = task, %FixPlan{} = fix_plan) do
    content =
      fix_plan
      |> Map.take([
        :round,
        :plan,
        :covered_keys,
        :covered_comments,
        :version,
        :saved_at,
        :approved_by,
        :approved_at
      ])
      |> Map.put(:findings, Enum.map(fix_plan.findings, &Map.take(&1, [:key, :title])))
      |> Map.put(:comments, Enum.map(fix_plan.comments, &Map.take(&1, [:number, :kind, :place, :text])))

    write_scratch_file(
      Path.join([task.scratch_path, "fix_plans", "#{identifier}.json"]),
      Jason.encode!(content, pretty: true)
    )
  end
end
