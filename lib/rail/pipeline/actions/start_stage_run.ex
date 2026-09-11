defmodule Rail.Pipeline.Actions.StartStageRun do
  @moduledoc """
  Action that starts a stage execution run for a task under a supervised task.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.Briefs
  import Rail.Pipeline.Utils.IssueIdentifier
  import Rail.Pipeline.Utils.PrepareScratch

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun

  @doc """
  Initiates a stage run for a given task:
  - Resolves stage role (or engineer role for rebasing).
  - Ensures worktree directory exists.
  - Prepares the task's scratch directory.
  - Records branch fingerprints and increments role run attempt.
  - Generates stage brief and CLI argv/prompt.
  - Spawns runner process and attaches follower.
  - Transitions task to `:running` and broadcasts `pipeline_changed`.
  """
  def start_stage_run(task_or_id, opts \\ []) do
    case resolve_task(task_or_id) do
      %Task{} = task -> do_start_stage_run(task, opts)
      nil -> {:error, :not_found}
    end
  end

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(task_id) when is_binary(task_id), do: Repo.get(Task, task_id)
  defp resolve_task(_other), do: nil

  defp do_start_stage_run(%Task{} = task, opts) do
    stage = if task.is_rebasing, do: :engineer, else: task.stage

    case Repo.get(Project, task.project_id) do
      %Project{} = project ->
        case Roles.get_role(project_id: project.id, stage: stage) do
          {:ok, %Role{} = role} ->
            execute_stage_run(task, project, role, stage, opts)

          {:error, _reason} ->
            handle_missing_role(task, stage)
        end

      nil ->
        {:error, :project_not_found}
    end
  end

  defp execute_stage_run(%Task{} = task, %Project{} = project, %Role{} = role, stage, opts) do
    base_branch = project.default_branch

    case Git.get_or_create_worktree(project, task) do
      {:ok, resolved_wt_path} ->
        proceed_with_worktree(task, role, stage, resolved_wt_path, base_branch, opts)

      {:error, reason} ->
        handle_worktree_failure(task, reason)
    end
  end

  defp proceed_with_worktree(task, role, stage, worktree_path, base_branch, opts) do
    task = maybe_update_worktree_path(task, worktree_path)

    {:ok, _scratch} = prepare_scratch(task)

    {:ok, role_run} = Runs.start_or_resume_role_run(task, role, worktree_path)

    identifier = issue_identifier(task)
    brief = build_brief(task, worktree_path, base_branch, identifier, role, stage)
    plan_content = latest_plan_content(task)

    prompt =
      Runs.build_prompt(
        task: task,
        backend: role.backend,
        role_instructions: role.system_prompt,
        context_snippet: brief,
        plan: plan_content,
        pending_answer: role_run.pending_answer,
        conversation_id: role_run.conversation_id
      )

    argv =
      Runs.build_args(
        backend: role.backend,
        prompt: prompt,
        model: role.model,
        reasoning_effort: role.reasoning_effort || "high",
        read_only: role.stage == :review,
        system_prompt: role.system_prompt,
        conversation_id: role_run.conversation_id,
        work_dir: worktree_path
      )

    spawn_and_finalize(task, role, role_run, argv, worktree_path, opts)
  end

  defp spawn_and_finalize(task, role, role_run, argv, worktree_path, opts) do
    on_finished_cb =
      Keyword.get(opts, :on_finished) ||
        fn _run, outcome ->
          Rail.Pipeline.settle_run(task.id, role_run.id, outcome, opts)
        end

    spawner_opts =
      opts
      |> Keyword.put_new(:backend, role.backend)
      |> Keyword.put_new(:cd, worktree_path)
      |> Keyword.put(:on_finished, on_finished_cb)

    case Runs.start_run(role_run, :stage, argv, spawner_opts) do
      {:ok, run} ->
        {:ok, updated_role_run} =
          role_run
          |> RoleRun.changeset(%{pending_answer: nil, attempt_log_lines: 0})
          |> Repo.update()

        {:ok, updated_task} =
          task
          |> Task.changeset(%{stage_state: :running})
          |> Repo.update()

        Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :dispatched})

        {:ok, %{task: updated_task, role_run: updated_role_run, run: run}}

      {:error, reason} ->
        error_text = "Failed to spawn runner: #{inspect(reason)}"

        {:ok, updated_task} =
          task
          |> Task.changeset(%{stage_state: :failed, error: error_text})
          |> Repo.update()

        Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :dispatch_failed})

        {:error, {:spawn_failed, reason, updated_task}}
    end
  end

  defp maybe_update_worktree_path(%Task{worktree_path: path} = task, path), do: task

  defp maybe_update_worktree_path(%Task{} = task, new_path) do
    {:ok, updated} = task |> Task.changeset(%{worktree_path: new_path}) |> Repo.update()
    updated
  end

  defp build_brief(task, worktree_path, base_branch, identifier, role, stage) do
    stage_brief(task,
      worktree_path: worktree_path,
      base_branch: base_branch,
      identifier: identifier,
      role: role.stage || stage,
      is_rebasing: task.is_rebasing
    )
  end

  defp latest_plan_content(task) do
    Repo.one(
      from p in Plan,
        where: p.task_id == ^task.id,
        order_by: [desc: p.captured_at, desc: p.inserted_at],
        select: p.content,
        limit: 1
    )
  end

  defp handle_missing_role(task, stage) do
    error_msg = "No role is configured for the #{stage} stage"

    {:ok, updated_task} =
      task
      |> Task.changeset(%{stage_state: :failed, error: error_msg})
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :dispatch_failed})

    {:error, :role_not_found}
  end

  defp handle_worktree_failure(task, reason) do
    error_msg = "Failed to create worktree: #{inspect(reason)}"

    {:ok, updated_task} =
      task
      |> Task.changeset(%{stage_state: :failed, error: error_msg})
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :dispatch_failed})

    {:error, {:worktree_failed, reason}}
  end
end
