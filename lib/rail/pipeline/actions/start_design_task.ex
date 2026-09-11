defmodule Rail.Pipeline.Actions.StartDesignTask do
  @moduledoc """
  Starts the design stage for a task, end to end.

  Everything the design stage needs lives here: the worktree, the scratch tree the
  agent reads its ticket from and writes its directions into, the brief describing
  both, and the spawned run.
  """

  import Ecto.Query

  alias Rail.Domain.TicketBody
  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Utils.Scratch
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.ArgvBuilder
  alias Rail.Runs.PromptBuilder
  alias Rail.Runs.Schemas.RoleRun

  @doc """
  Starts the design stage for `task_or_id`.

  Moves the task to the `:design` stage, reusing the worktree it already has, and
  spawns the design role against the approved ticket. Returns
  `{:ok, %{task: task, role_run: role_run, run: run}}`.
  """
  def start_design_task(task_or_id, opts \\ []) when is_list(opts) do
    with %Task{project: %Project{} = project} = task <- resolve_task(task_or_id),
         {:ok, %Role{} = role} <- Roles.get_role(project_id: project.id, stage: :design),
         {:ok, worktree_path} <- ensure_worktree(project, task, opts),
         {:ok, task} <- claim_stage(task, worktree_path),
         scratch_path = write_scratch(project, task, opts),
         {:ok, role_run} <- role_run_for(task, role, worktree_path) do
      spawn_run(task, project, role, role_run, worktree_path, scratch_path, opts)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # The worktree and the scratch tree

  defp ensure_worktree(%Project{} = project, %Task{} = task, opts) do
    base_branch = Keyword.get(opts, :base_branch) || project.default_branch || "main"
    name = task.worktree_name || task.id

    path =
      task.worktree_path ||
        Keyword.get(opts, :worktree_path) ||
        Path.join(project.clone_path, ".worktrees/#{name}")

    case Git.get_or_create_worktree(project.clone_path, path, name, base_branch: base_branch) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:worktree_failed, reason}}
    end
  end

  defp claim_stage(%Task{} = task, worktree_path) do
    task
    |> Task.changeset(%{stage: :design, worktree_path: worktree_path, retry_after: nil, error: nil})
    |> Repo.update()
  end

  defp write_scratch(%Project{} = project, %Task{} = task, opts) do
    scratch_path =
      Keyword.get(opts, :scratch_dir) ||
        Keyword.get(opts, :scratch_path) ||
        Scratch.default_scratch_path(project, task)

    File.mkdir_p!(Path.join(scratch_path, "design"))

    case task.issue do
      %Issue{} = issue ->
        tickets_dir = Path.join(scratch_path, "tickets")
        File.mkdir_p!(tickets_dir)

        content =
          TicketBody.format(%TicketBody{
            title: task.title || issue.title || "",
            description: task.description || issue.description || "",
            priority: issue.priority,
            estimate: issue.estimate
          })

        tickets_dir |> Path.join("#{issue.identifier}.md") |> File.write!(content)

      nil ->
        :ok
    end

    scratch_path
  end

  # The run

  defp role_run_for(%Task{} = task, %Role{} = role, worktree_path) do
    {head_sha, dirty_digest} =
      case Git.branch_fingerprint(worktree_path, []) do
        %{head_sha: sha, dirty_digest: digest} -> {sha, digest}
        _other -> {nil, nil}
      end

    attrs = %{
      status: :running,
      started_at: DateTime.utc_now(),
      stage_fingerprint_head_sha: head_sha,
      stage_fingerprint_dirty_digest: dirty_digest
    }

    case Repo.one(from r in RoleRun, where: r.task_id == ^task.id and r.role_id == ^role.id) do
      %RoleRun{} = existing ->
        existing
        |> RoleRun.changeset(Map.put(attrs, :attempts, (existing.attempts || 0) + 1))
        |> Repo.update()

      nil ->
        %RoleRun{}
        |> RoleRun.changeset(Map.merge(attrs, %{task_id: task.id, role_id: role.id, attempts: 1}))
        |> Repo.insert()
    end
  end

  defp brief(%Task{} = task) do
    ticket_line =
      case task.issue do
        %Issue{identifier: identifier} ->
          "The ticket you are designing for is the file $RAIL_SCRATCH/tickets/#{identifier}.md. It is not yours to edit.\n\n"

        nil ->
          ""
      end

    String.trim("""
    #{ticket_line}Produce three distinct design directions on a single published canvas, and never edit application code on this stage.

    Rail reads the directions from $RAIL_SCRATCH/design/. Save a still screenshot of each one there, and write the manifest to $RAIL_SCRATCH/design/manifest.json with this shape:
    {
      "canvasUrl": "<absolute https URL to the published canvas>",
      "version": 1,
      "directions": [
        {
          "key": "<unique-key>",
          "title": "<title of direction>",
          "notes": "<notes on what it does differently>",
          "stillPath": "$RAIL_SCRATCH/design/<still>.png"
        }
      ],
      "pickedKey": null
    }

    A human picks one of the directions before anything is planned. Stop once the canvas is published, the stills are captured and the manifest is written.
    """)
  end

  defp workspace_brief(%Task{} = task, %Project{} = project, worktree_path, opts) do
    base_branch = Keyword.get(opts, :base_branch) || project.default_branch || "main"

    String.trim("""
    Workspace for this task:
    - Worktree: #{worktree_path} (your working directory; every path you touch is under it)
    - Branch: #{task.worktree_name || task.id}, already checked out. Do NOT create a branch of your own, and do not rename this one.
    - Base branch: #{base_branch} on remote `origin`
    - Other agents share this repository. Never switch branches, never work in the main checkout, and never touch another worktree.
    """)
  end

  defp spawn_run(task, project, role, role_run, worktree_path, scratch_path, opts) do
    context =
      [workspace_brief(task, project, worktree_path, opts), brief(task)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    prompt =
      PromptBuilder.build_prompt(
        task: task,
        backend: role.cli_backend,
        role_instructions: role.system_prompt,
        system_prompt: role.system_prompt,
        context_snippet: context,
        pending_answer: role_run.pending_answer,
        conversation_id: role_run.conversation_id
      )

    argv =
      ArgvBuilder.build_argv(
        backend: role.cli_backend,
        prompt: prompt,
        model: role.model,
        reasoning_effort: role.reasoning_effort || "high",
        system_prompt: role.system_prompt,
        conversation_id: role_run.conversation_id,
        work_dir: worktree_path
      )

    spawner_opts =
      opts
      |> Keyword.put_new(:backend, role.cli_backend)
      |> Keyword.put_new(:cd, worktree_path)
      |> Keyword.put_new(:scratch_path, scratch_path)
      |> Keyword.put_new(:on_finished, fn _run, outcome ->
        Pipeline.settle_run(task.id, role_run.id, outcome, opts)
      end)

    case Runs.start_run(role_run, :stage, argv, spawner_opts) do
      {:ok, run} -> finalize(task, role_run, run)
      {:error, reason} -> fail(task, reason)
    end
  end

  defp finalize(task, role_run, run) do
    {:ok, role_run} =
      role_run
      |> RoleRun.changeset(%{pending_answer: nil, attempt_log_lines: 0})
      |> Repo.update()

    {:ok, task} = task |> Task.changeset(%{stage_state: :running}) |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :dispatched})

    {:ok, %{task: task, role_run: role_run, run: run}}
  end

  defp fail(task, reason) do
    {:ok, task} =
      task
      |> Task.changeset(%{stage_state: :failed, error: "Failed to spawn runner: #{inspect(reason)}"})
      |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :dispatch_failed})

    {:error, {:spawn_failed, reason, task}}
  end

  # The project and the issue are carried on the task from here on: every step below
  # needs them, and none of them should be refetching either.
  defp resolve_task(%Task{} = task), do: Repo.preload(task, [:project, :issue])
  defp resolve_task(id) when is_binary(id), do: Task |> Repo.get(id) |> resolve_task()
  defp resolve_task(_other), do: nil
end
