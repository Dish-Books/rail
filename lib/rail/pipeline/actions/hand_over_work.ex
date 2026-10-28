defmodule Rail.Pipeline.Actions.HandOverWork do
  @moduledoc """
  Sends on what the engineer committed, through CI where the project has it and then pushed, and on to the next
  stage: Review, where Rail starts the agents that check the round, or a custom stage placed before it.
  """

  import Rail.Pipeline.Utils.CiPassed
  import Rail.Pipeline.Utils.OpenPullRequest
  import Rail.Pipeline.Utils.StartCi

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @doc """
  Sends on the commits on `run`'s branch that the remote does not have yet. Returns `{:ok, run}`, running
  while CI decides, or `{:error, reason}` when the run is not its stage's, there is nothing to send, the
  branch does not extend what its remote branch holds (`:history_rewritten`, `:pushed_outside_rail`), or
  git, GitHub, CI or review refused. Safe to run again after a push that failed.
  """
  def hand_over_work(%Scope{} = scope, %Run{} = run) do
    %Run{task: %Task{project: %Project{ci_command: command}} = task} =
      run = Run |> Repo.get!(run.id) |> Repo.preload([:role, task: [:issue, :project]], force: true)

    with :ok <- handable(task, run),
         :ok <- Git.check_push(task) do
      # Set before CI starts, so a CI that finishes fast still finds it.
      flagged = update(run, %{review_on_ci_pass: true})

      if command in [nil, ""] or ci_passed?(task),
        do: push(scope, flagged),
        else: run_ci(flagged)
    end
  end

  # Only the engineer commits, so the branch is its to hand over while the task is at Engineer.
  defp handable(%Task{stage: stage} = task, %Run{role: %Role{stage: role_stage}}) do
    cond do
      {stage, role_stage} != {:engineer, :engineer} -> {:error, {:invalid_stage, stage}}
      not Git.branch_unpushed?(task.worktree_path) -> {:error, :nothing_to_send}
      true -> :ok
    end
  end

  # Pushed once CI has passed on HEAD, and sent on once pushed; CI's finish does both where it runs.
  defp push(%Scope{} = scope, %Run{task: %Task{} = task} = run) do
    case Git.push_branch(scope, task) do
      :ok ->
        pushed = %{update(run, %{review_on_ci_pass: false, error: nil}) | task: open_pull_request(task, run)}
        Pipeline.send_to_next_stage(pushed)

      {:error, reason} ->
        _cleared = update(run, %{review_on_ci_pass: false})
        {:error, reason}
    end
  end

  defp run_ci(%Run{} = run) do
    case start_ci(run) do
      {:ok, _os_process} ->
        {:ok, %{Repo.get!(Run, run.id) | task: run.task, role: run.role}}

      {:error, %Run{error: error} = failed} ->
        _cleared = update(failed, %{review_on_ci_pass: false})
        {:error, error}
    end
  end

  defp update(%Run{} = run, attrs) do
    {:ok, updated} = run |> Run.changeset(attrs) |> Repo.update()
    %{updated | task: run.task, role: run.role}
  end
end
