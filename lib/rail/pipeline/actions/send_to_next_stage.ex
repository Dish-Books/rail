defmodule Rail.Pipeline.Actions.SendToNextStage do
  @moduledoc """
  Hands the engineer's work to the next stage of its task's sequence, by a person's click or once CI passes on the
  engineer's commit: Review, or a custom stage placed before it.

  The engineer's commits are the artifact, so there is nothing to capture here: the branch already carries
  everything. A custom stage runs once per task, so a later round's work goes past one already approved, to
  Review, where Rail starts QA and the code reviewer on the round.

  A branch the remote has never heard of is refused, since it is not a branch anyone else can review; the diff
  pane's Push sends it. Work left uncommitted is not the engineer's to hand over, so it stays behind in the worktree.
  """

  import Rail.Pipeline.Utils.CiPassed
  import Rail.Pipeline.Utils.StartChecks

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  @doc """
  Sends `run`'s task on from Engineer to the next stage. Returns `{:ok, run}`, the run that was handed in, latched
  done.
  """
  def send_to_next_stage(%Run{} = run) do
    run = Repo.preload(run, [task: [:issue, :project, runs: :role]], force: true)

    with :ok <- sendable(run.task) do
      {:ok, latched} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
      {:ok, _entered} = enter_next_stage(run.task, next_stage(run.task))

      {:ok, %{latched | task: run.task, role: run.role}}
    end
  end

  # At Review the agents that check the round start, and anywhere else the stage's own agent on a clean conversation.
  defp enter_next_stage(%Task{} = task, :review) do
    {:ok, reviewing} = Pipeline.enter_stage(task, :review, start: false)
    # A round that brought the branch up to date clears its Update, and one that did not may still need it.
    {:ok, reviewing} = Pipeline.check_base(reviewing)
    :ok = start_checks(reviewing)
    {:ok, reviewing}
  end

  defp enter_next_stage(%Task{} = task, stage), do: Pipeline.enter_stage(task, stage, fresh: true)

  defp sendable(%Task{stage: stage}) when stage != :engineer, do: {:error, {:invalid_stage, stage}}

  defp sendable(%Task{} = task) do
    cond do
      Task.running?(task) -> {:error, :stage_running}
      Git.branch_unpushed?(task.worktree_path) -> {:error, :unpushed_changes}
      ci_required?(task) and not ci_passed?(task) -> {:error, :ci_not_passed}
      true -> :ok
    end
  end

  defp next_stage(%Task{issue: %Issue{} = issue, runs: runs}) do
    approved = for %Run{role: %Role{custom_stage: name}, stage_outcome: :done} <- runs, is_binary(name), do: name

    issue
    |> Issue.calculate_stages()
    |> Enum.drop_while(&(&1 != :engineer))
    |> Enum.drop(1)
    |> Enum.reject(&(match?({:custom, _name}, &1) and elem(&1, 1) in approved))
    |> List.first()
  end

  defp ci_required?(%Task{project: %Project{ci_command: command}}), do: command not in [nil, ""]
end
