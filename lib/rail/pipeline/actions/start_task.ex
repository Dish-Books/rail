defmodule Rail.Pipeline.Actions.StartTask do
  @moduledoc """
  Starts an issue's task at the first of its stages: Plan, or Engineer when its workflow turned every Plan step off.
  """

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Creates the task for `issue` at its first stage, starts its run and returns `{:ok, task}`. A checkout no worktree
  can be made in leaves the issue without a task, so it can be started again.
  """
  def start_task(%Issue{} = issue) do
    case Issue.calculate_stages(issue) do
      [:plan | _later] ->
        with {:ok, %OsProcess{task_id: task_id}} <- Pipeline.start_plan_run(issue), do: Pipeline.get_task(task_id)

      [:engineer | _later] ->
        with {:ok, %Task{} = task} <- record_task(Repo.preload(issue, :project)) do
          {:ok, _run} = Pipeline.enter_stage(task, :engineer, fresh: true)
          Pipeline.get_task(task.id)
        end
    end
  end

  # Nothing was planned, so round 1 holds the issue as its ticket, approved by Rail so Merge waits on no plan.
  defp record_task(%Issue{project: %Project{} = project} = issue) do
    Repo.transaction(fn ->
      with {:ok, task} <- Pipeline.create_task(issue, :engineer),
           {:ok, _round} <- issue_round(task, issue),
           {:ok, _worktree_path} <- worktree(project, task) do
        task
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # A second start, from another tab, finds the task and its round already there.
  defp issue_round(%Task{} = task, %Issue{} = issue) do
    case Pipeline.read_plan(task) do
      %Round{} = round ->
        {:ok, round}

      nil ->
        {:ok, round} = Pipeline.create_round(task)
        round |> Round.approve_changeset(nil) |> Round.issue_ticket_changeset(issue) |> Repo.update()
    end
  end

  defp worktree(%Project{} = project, %Task{} = task) do
    case Git.get_or_create_worktree(project, task) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:worktree_failed, reason}}
    end
  end
end
