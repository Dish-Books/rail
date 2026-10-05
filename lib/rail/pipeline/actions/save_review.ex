defmodule Rail.Pipeline.Actions.SaveReview do
  @moduledoc """
  Records that a review pass is finished, which is what tells a review that found
  nothing apart from one that never finished.
  """

  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Closes `task`'s review. Returns `{:ok, saved_at}`.
  """
  def save_review(%Task{} = task) do
    %Task{issue: %Issue{identifier: identifier}} = task = Repo.preload(task, :issue)
    saved_at = DateTime.utc_now()

    write_scratch_file(
      Path.join([task.scratch_path, "reviews", "#{identifier}.json"]),
      Jason.encode!(%{saved_at: saved_at})
    )

    {:ok, saved_at}
  end
end
