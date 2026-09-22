defmodule Rail.Pipeline.Actions.ChangedSinceReview do
  @moduledoc false

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  @doc """
  True when `task`'s branch is on a commit its reviewer has not started a pass on:
  it has never been reviewed, or the engineer has changed it since.
  """
  def changed_since_review?(%Task{} = task) do
    with {:ok, %Role{id: role_id}} <- Roles.get_role(project_id: task.project_id, stage: :review),
         %Run{stage_fingerprint_head_sha: reviewed} when is_binary(reviewed) <-
           Repo.get_by(Run, task_id: task.id, role_id: role_id) do
      not match?(%{head_sha: ^reviewed}, Git.branch_fingerprint(task.worktree_path))
    else
      _never_reviewed -> true
    end
  end
end
