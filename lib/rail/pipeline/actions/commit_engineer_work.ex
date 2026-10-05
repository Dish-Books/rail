defmodule Rail.Pipeline.Actions.CommitEngineerWork do
  @moduledoc """
  Commits what the engineer left in its worktree and sends it on: pushed, or for
  a project with CI, run through CI first, which pushes it once it passes.

  Rail commits rather than the agent, because who a commit belongs to and what it
  is signed with are not decisions to leave to a prompt. What this stage owns is
  the message - the words the engineer handed over with `commit`, plus the
  trailers naming the ticket and Rail. Who the commit is by, what signs it and what pushes it are
  `Rail.Git`'s to answer.
  """

  import Rail.Pipeline.Utils.CiPassed
  import Rail.Pipeline.Utils.CommitMessage
  import Rail.Pipeline.Utils.OpenPullRequest
  import Rail.Pipeline.Utils.ReturnToEngineer
  import Rail.Pipeline.Utils.StartCi

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @doc """
  Commits everything in `task`'s worktree under `message`, then pushes the branch
  or starts CI on the engineer's run. With no message, the commit says it holds
  follow-up changes.

  Returns `:ok`, or `{:error, reason}` when git, GitHub or CI refused. Safe to
  run again after either half failed: it is the outstanding work it acts on, not
  a fixed pair of steps.
  """
  def commit_engineer_work(%Scope{} = scope, %Task{} = task, message) do
    task = Repo.preload(task, [:issue, :project])

    with {:ok, sha} <- commit(scope, task, message),
         {:ok, _task} <- return_if_committed(sha, task) do
      send_on(scope, task)
    end
  end

  # A commit CI has not passed is not pushed: CI's finish pushes it.
  defp send_on(%Scope{} = scope, %Task{project: %Project{ci_command: command}} = task) do
    if command in [nil, ""] or ci_passed?(task), do: push(scope, task), else: start_engineer_ci(task)
  end

  defp push(%Scope{} = scope, %Task{} = task) do
    with :ok <- Git.push_branch(scope, task) do
      _task = open_pull_request(task, engineer_run(task))
      :ok
    end
  end

  defp start_engineer_ci(%Task{} = task) do
    case start_ci(engineer_run(task)) do
      {:ok, _os_process} -> :ok
      {:error, %Run{error: error}} -> {:error, error}
    end
  end

  defp engineer_run(%Task{} = task) do
    {:ok, %Role{id: role_id}} = Roles.get_role(project_id: task.project_id, stage: :engineer)
    Run |> Repo.get_by!(task_id: task.id, role_id: role_id) |> Repo.preload([:task, role: :backend])
  end

  # A push that failed leaves a commit that was made and never sent, so running
  # this again has nothing to commit and everything still to push.
  defp commit(%Scope{} = scope, %Task{worktree_path: worktree_path} = task, message) do
    if Git.worktree_dirty?(worktree_path),
      do: Git.commit_worktree(scope, task, commit_message(task, message)),
      else: {:ok, :nothing_to_commit}
  end

  # Code changed past Engineer is reviewed again, even when the push then fails.
  defp return_if_committed(:nothing_to_commit, %Task{} = task), do: {:ok, task}
  defp return_if_committed(_sha, %Task{} = task), do: return_to_engineer(task)
end
