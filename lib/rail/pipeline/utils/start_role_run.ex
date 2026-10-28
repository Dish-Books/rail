defmodule Rail.Pipeline.Utils.StartRoleRun do
  @moduledoc """
  Starts a role's run on a task: the run is marked running, the worktree made ready, and the role's agent spawned
  on its own brief. Rail starts every agent this way, one run a role, and none leads another: the one subagent is
  the check Plan and the review agent have read each plan they save.
  """

  import Rail.Pipeline.Utils.PrepareWorktree
  import Rail.Pipeline.Utils.StartWorktreeSetup

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  @doc """
  Starts `role`'s run on `task` and returns `{:ok, run}` as it now stands, running or failed on why it could not
  start. `fresh: true` starts a new conversation rather than resuming the run's last, as each round does.
  """
  def start_role_run(%Task{} = task, %Role{} = role, opts \\ []) do
    # The run is started before the spawn is attempted, since starting it is what unlatches it, and every way
    # out settles it: a run left running with no process behind it is one nothing recovers.
    {task, worktree_path} = worktree(task)
    {:ok, %Run{} = run} = Pipeline.start_or_resume_run(task, role, worktree_path, opts)

    if worktree_path do
      case start_worktree_setup(run) do
        # The run's own role is the stored row; this one carries the prompt the repo merged.
        :not_needed -> start_agent(%{run | role: role})
        {:ok, os_process} -> {:ok, os_process.run}
        {:error, %Run{} = failed} -> {:ok, failed}
      end
    else
      {:ok, fail(run, "Could not prepare the worktree at #{task.worktree_path}.")}
    end
  end

  defp start_agent(%Run{} = run) do
    case start_process(run) do
      {:ok, os_process} -> {:ok, os_process.run}
      {:error, {:spawn_failed, _reason, %Run{} = failed}} -> {:ok, failed}
      {:error, :dispatch_disabled} -> {:ok, fail(run, "Dispatch is off, so no agent was started for this stage.")}
    end
  end

  defp worktree(%Task{} = task) do
    with %Project{} = project <- Repo.get(Project, task.project_id),
         {:ok, task, resolved} <- prepare_worktree(project, task) do
      {task, resolved}
    else
      _unavailable -> {task, nil}
    end
  end

  defp fail(%Run{} = run, error) do
    {:ok, run} = run |> Run.changeset(%{error: error, status: :failed}) |> Repo.update()
    run
  end

  # Each stage spawns itself on a brief of its own.
  # The run carries its task and its role, so it is the whole of what a spawn needs.
  defp start_process(%Run{role: %Role{stage: :plan}} = run), do: Pipeline.start_plan_run(run)
  defp start_process(%Run{role: %Role{stage: :engineer}} = run), do: Pipeline.start_engineer_run(run)
  defp start_process(%Run{role: %Role{stage: :review_lead}} = run), do: Pipeline.start_review_run(run)

  defp start_process(%Run{role: %Role{stage: stage}} = run) when stage in [:qa, :review, :demo],
    do: Pipeline.start_check_run(run)

  defp start_process(%Run{role: %Role{custom_stage: name}} = run) when is_binary(name),
    do: Pipeline.start_custom_stage_run(run)
end
