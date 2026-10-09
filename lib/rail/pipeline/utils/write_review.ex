defmodule Rail.Pipeline.Utils.WriteReview do
  @moduledoc false

  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Writes `passes`, as `read_review/1` reads them, as `task`'s review file. Requires `issue` loaded.
  """
  def write_review(%Task{issue: %Issue{identifier: identifier}} = task, passes) do
    write_scratch_file(
      Path.join([task.scratch_path, "reviews", "#{identifier}.json"]),
      Jason.encode!(%{passes: Enum.map(passes, &Map.take(&1, [:round, :saved_at, :head, :finished_at]))})
    )
  end
end
