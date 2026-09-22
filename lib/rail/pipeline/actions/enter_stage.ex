defmodule Rail.Pipeline.Actions.EnterStage do
  @moduledoc """
  Moves a task to a stage and starts that stage's run.

  This is the only thing that writes `task.stage`, and the only thing that puts a
  run back to `:in_progress`. Both halves belong together: entering a stage is
  exactly the moment that stage gets to conclude something again, so a reviewer
  that already passed can pass afresh on the rework, and an engineer that already
  said it was done can say it about the next round.

  Nothing settles its way here. A run that finishes decides what its own stage
  concluded and then calls this if that conclusion means moving; the move is
  never a side effect of a process exiting.
  """

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools

  @doc """
  Enters `stage` on `task` and spawns the role that stage belongs to.

  Returns `{:ok, run}` with the run left executing, or `{:ok, task}` when the
  project has bound no role to that stage, which records the move and stops there.
  """
  def enter_stage(%Task{} = task, stage, _opts \\ []) when is_atom(stage) do
    {:ok, task} = claim_stage(task, stage)

    case Roles.get_role(project_id: task.project_id, stage: stage) do
      {:ok, %Role{} = role} -> start_role(task, role)
      {:error, :role_not_found} -> {:ok, task}
    end
  end

  defp claim_stage(%Task{} = task, stage) do
    task
    |> Task.changeset(%{stage: stage})
    |> Repo.update()
  end

  # The run is started before the spawn is attempted, because starting it is what
  # unlatches the stage. A worktree Rail cannot make is a failure to record on the
  # run, not a reason for the stage never to have been entered.
  #
  # Every way out of here settles the run, including the spawn that never
  # happened. A run left at `:running` with no OS process behind it is a run
  # nothing recovers: `Boot.reconcile/1` works from `os_processes` rows and there
  # is none, so it survives every restart, reads as busy, and hides the buttons
  # that would move it on.
  defp start_role(%Task{} = task, %Role{} = role) do
    worktree_path = worktree(task)
    {:ok, %Run{} = run} = Pipeline.start_or_resume_run(task, role, worktree_path)

    if worktree_path do
      case start_process(run) do
        {:ok, os_process} -> {:ok, os_process.run}
        {:error, {:spawn_failed, _reason, %Run{} = failed}} -> {:ok, failed}
        {:error, :dispatch_disabled} -> {:ok, fail(run, "Dispatch is off, so no agent was started for this stage.")}
      end
    else
      {:ok, fail(run, "Could not prepare the worktree at #{task.worktree_path}.")}
    end
  end

  defp worktree(%Task{} = task) do
    with %Project{} = project <- Repo.get(Project, task.project_id),
         {:ok, resolved} <- Git.get_or_create_worktree(project, task) do
      resolved
    else
      _unavailable -> nil
    end
  end

  defp fail(%Run{} = run, error) do
    {:ok, run} = run |> Run.changeset(%{error: error, status: :failed}) |> Repo.update()
    run
  end

  # A stage with a brief of its own spawns itself; the rest have nothing to add.
  # The run carries its task and its role, so it is the whole of what a spawn needs.
  defp start_process(%Run{role: %Role{stage: :design}} = run), do: Pipeline.start_design_run(run)
  defp start_process(%Run{role: %Role{stage: :architect}} = run), do: Pipeline.start_architect_run(run)
  defp start_process(%Run{role: %Role{stage: :engineer}} = run), do: Pipeline.start_engineer_run(run)
  defp start_process(%Run{role: %Role{stage: :review}} = run), do: Pipeline.start_review_run(run)
  defp start_process(%Run{role: %Role{stage: :qa}} = run), do: Pipeline.start_qa_run(run)
  defp start_process(%Run{role: %Role{stage: :demo}} = run), do: Pipeline.start_demo_run(run)

  defp start_process(%Run{task: %Task{} = task, role: %Role{} = role} = run) do
    prompt =
      Pipeline.build_prompt(
        task: task,
        backend: role.backend,
        role_instructions: role.system_prompt,
        context_snippet: "",
        pending_answer: run.pending_answer,
        conversation_id: run.conversation_id
      )

    argv =
      Tools.build_args(
        backend: role.backend,
        prompt: prompt,
        model: role.model,
        reasoning_effort: role.reasoning_effort || "high",
        system_prompt: role.system_prompt,
        conversation_id: run.conversation_id,
        work_dir: task.worktree_path
      )

    Tools.start_os_process(run, argv)
  end
end
