defmodule Rail.Pipeline.Actions.StartTask do
  @moduledoc """
  Starts an issue's task at the first of its stages: Plan, a custom stage its workflow placed first, or Engineer when
  its workflow turned every Plan step off. The person who starts an unowned issue becomes its owner.
  """

  import Rail.Pipeline.Utils.ClaimForStarter

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Creates the task for `issue` at its first stage, starts its run and returns `{:ok, task}`, or `{:error, reason}`:
  `:not_found`, `:task_exists` for a second start, or what the worktree or the spawn refused.
  """
  def start_task(%Scope{} = scope, %Issue{} = issue) do
    if Scope.can_access_project?(scope, issue.project_id), do: start(scope, issue), else: {:error, :not_found}
  end

  defp start(%Scope{} = scope, %Issue{} = issue) do
    case Issue.calculate_stages(issue) do
      [:plan | _later] ->
        with {:ok, %OsProcess{task_id: task_id}} <- Pipeline.start_plan_run(scope, issue),
             do: Pipeline.get_task(task_id)

      [first | _later] = stages ->
        with {:ok, %Task{} = task} <- record_task(scope, Repo.preload(issue, :project), first, :plan in stages) do
          Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, issue.id})
          {:ok, _run} = Pipeline.enter_stage(task, first, fresh: true)
          Pipeline.get_task(task.id)
        end
    end
  end

  # With no Plan to come, round 1 holds the issue as its ticket, approved by Rail so Merge waits on no plan.
  # The claim is last because it locks the issue's row, which no git fetch should hold.
  defp record_task(%Scope{} = scope, %Issue{project: %Project{} = project} = issue, first, planned?) do
    Repo.transaction(fn ->
      with {:ok, task} <- Pipeline.create_task(issue, first),
           {:ok, _round} <- if(planned?, do: {:ok, nil}, else: issue_round(task, issue)),
           {:ok, _worktree_path} <- worktree(project, task),
           :ok <- claim_for_starter(scope, issue) do
        task
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp issue_round(%Task{} = task, %Issue{} = issue) do
    {:ok, round} = Pipeline.create_round(task)
    round |> Round.approve_changeset(nil) |> Round.issue_ticket_changeset(issue) |> Repo.update()
  end

  defp worktree(%Project{} = project, %Task{} = task) do
    case Git.get_or_create_worktree(project, task) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:worktree_failed, reason}}
    end
  end
end
