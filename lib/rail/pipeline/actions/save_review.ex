defmodule Rail.Pipeline.Actions.SaveReview do
  @moduledoc """
  Records that a Review pass is finished, as the next entry in the review file: its round, when, and the
  commit it read. That is what tells a pass that found nothing apart from one that never finished.
  """

  import Rail.Pipeline.Utils.WriteReview

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Closes the pass running on `task`. Returns `{:ok, pass}`.
  """
  def save_review(%Task{} = task) do
    task = Repo.preload(task, :issue)
    passes = Pipeline.read_review(task)
    head = if Task.worktree_present?(task), do: Git.branch_fingerprint(task.worktree_path)[:head_sha]
    pass = %{round: length(passes) + 1, saved_at: DateTime.utc_now(), head: head, finished_at: nil}

    write_review(task, List.insert_at(passes, -1, pass))

    Pipeline.broadcast_output_saved(task)

    {:ok, pass}
  end
end
