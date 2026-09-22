defmodule Rail.Pipeline.Actions.RebaseTask do
  @moduledoc """
  Rebases the task's branch onto the default branch.

  Rail fetches and rebases itself, and a rebase that goes through cleanly needs
  nobody: it is sent on as any finished round is. Only one that stops on a
  conflict goes to the engineer, because a conflict is a question about the code.
  """

  import Rail.Pipeline.Utils.RebasePass

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @doc """
  Fetches the default branch and rebases onto it. Returns `{:ok, task}`, with the
  branch sent on or the engineer resolving conflicts, or `{:error, reason}`.
  """
  def rebase_task(%Scope{} = scope, %Task{} = task) do
    %Task{project: %Project{} = project} = task = Repo.preload(task, [:project, :runs], force: true)

    with :ok <- rebasable(task),
         {:ok, %Run{} = run} <- engineer_run(task),
         :ok <- Git.fetch_default_branch(project, task.worktree_path),
         {:ok, _run} <- rebase_pass(scope, %{run | task: task}) do
      {:ok, Repo.reload!(task)}
    end
  end

  defp rebasable(%Task{} = task) do
    cond do
      is_struct(task.cleaned_up_at, DateTime) ->
        {:error, :cleaned_up}

      Task.running?(task) ->
        {:error, :task_busy}

      not Task.worktree_present?(task) ->
        {:error, :no_worktree}

      # A rebase stopped on conflicts is dirty by nature, and asking again carries it on.
      Git.worktree_dirty?(task.worktree_path) and not Git.rebase_in_progress?(task.worktree_path) ->
        {:error, :uncommitted_changes}

      true ->
        :ok
    end
  end

  defp engineer_run(%Task{} = task) do
    with {:ok, %Role{id: role_id}} <- Roles.get_role(project_id: task.project_id, stage: :engineer),
         %Run{} = run <- Repo.get_by(Run, task_id: task.id, role_id: role_id) do
      {:ok, Repo.preload(run, role: :backend)}
    else
      _never_built -> {:error, :no_engineer_run}
    end
  end
end
