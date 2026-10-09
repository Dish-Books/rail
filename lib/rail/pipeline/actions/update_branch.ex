defmodule Rail.Pipeline.Actions.UpdateBranch do
  @moduledoc """
  Merges the default branch into the task's branch.

  Rail fetches and merges itself, on the run of the stage the task is at, and a
  merge that goes through cleanly needs nobody: it is sent on as any finished
  round is. Only one that stops on a conflict goes to that run's agent, because a
  conflict is a question about the code. The task stays where it is.
  """

  import Rail.Pipeline.Utils.UpdateBranchPass

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @doc """
  Fetches the default branch and merges it in. Returns `{:ok, task}`, with the
  branch sent on or an agent resolving conflicts, or `{:error, reason}`.
  """
  def update_branch(%Scope{} = scope, %Task{} = task) do
    %Task{project: %Project{} = project} = task = Repo.preload(task, [:project, :runs], force: true)

    with :ok <- updatable(task),
         {:ok, %Run{} = run} <- stage_run(task),
         :ok <- Git.fetch_default_branch(project, task.worktree_path),
         {:ok, _run} <- update_branch_pass(scope, %{run | task: task}) do
      {:ok, Repo.reload!(task)}
    end
  end

  defp updatable(%Task{} = task) do
    cond do
      is_struct(task.cleaned_up_at, DateTime) ->
        {:error, :cleaned_up}

      Task.running?(task) ->
        {:error, :task_busy}

      not Task.worktree_present?(task) ->
        {:error, :no_worktree}

      # A merge stopped on conflicts is dirty by nature, and asking again carries it on.
      Git.worktree_dirty?(task.worktree_path) and not Git.merge_in_progress?(task.worktree_path) ->
        {:error, :uncommitted_changes}

      true ->
        :ok
    end
  end

  # At Review the branch is the Review lead's; anywhere else it is still the engineer's.
  defp stage_run(%Task{} = task) do
    stage = if task.stage == :review, do: :review_lead, else: :engineer
    {:ok, %Role{id: role_id}} = Roles.get_role(project_id: task.project_id, stage: stage)

    case Repo.get_by(Run, task_id: task.id, role_id: role_id) do
      %Run{} = run -> {:ok, Repo.preload(run, :role)}
      nil -> {:error, :no_stage_run}
    end
  end
end
