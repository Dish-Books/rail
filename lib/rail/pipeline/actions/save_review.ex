defmodule Rail.Pipeline.Actions.SaveReview do
  @moduledoc """
  Records that a Review pass is finished in the review file: a round is a read of a new HEAD, so saving
  again at the HEAD the open pass read is that round again rather than a new one.
  """

  import Rail.Pipeline.Utils.WriteReview

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  @doc """
  Closes the pass running on `task`. Returns `{:ok, pass}`.
  """
  def save_review(%Task{} = task) do
    task = Repo.preload(task, :issue)
    passes = Pipeline.read_review(task)
    head = if Task.worktree_present?(task), do: Git.branch_fingerprint(task.worktree_path)[:head_sha]
    now = DateTime.utc_now()

    {pass, passes} =
      case List.last(passes) do
        %{head: ^head, finished_at: nil} = last when is_binary(head) ->
          pass = %{last | saved_at: now}
          {pass, List.replace_at(passes, -1, pass)}

        _new_head ->
          pass = %{round: length(passes) + 1, saved_at: now, head: head, finished_at: nil}
          {pass, List.insert_at(passes, -1, pass)}
      end

    write_review(task, passes)
    if is_binary(head), do: stamp_lead_run(task, head)
    Pipeline.broadcast_output_saved(task)

    {:ok, pass}
  end

  # On the row as well as in scratch, which cleanup removes, so learnings can still compare against it.
  defp stamp_lead_run(%Task{} = task, head) do
    lead_runs =
      for %Run{role: %Role{stage: :review_lead}} = run <- Pipeline.list_runs(task_id: task.id, preload: :role), do: run

    with %Run{} = run <- List.last(lead_runs) do
      {:ok, _stamped} = run |> Run.changeset(%{stage_fingerprint_head_sha: head}) |> Repo.update()
    end
  end
end
