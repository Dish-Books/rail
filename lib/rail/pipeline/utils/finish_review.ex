defmodule Rail.Pipeline.Utils.FinishReview do
  @moduledoc """
  Finishes a task's Review: its last pass is marked finished, which is what reads as ready to merge, and its
  pull request leaves draft.
  """

  import Rail.Pipeline.Utils.MarkPullRequestReady
  import Rail.Pipeline.Utils.WriteReview

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Marks `task`'s last pass finished and its pull request ready. Returns the task as it now stands.
  """
  def finish_review(%Task{} = task) do
    task = Repo.preload(task, :issue)
    # Both callers finish only a review with a pass saved.
    [_first | _rest] = passes = Pipeline.read_review(task)
    last = List.last(passes)
    write_review(task, List.replace_at(passes, -1, %{last | finished_at: last.finished_at || DateTime.utc_now()}))
    mark_pull_request_ready(task)
  end
end
