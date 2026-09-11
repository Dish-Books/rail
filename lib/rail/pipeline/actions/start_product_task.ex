defmodule Rail.Pipeline.Actions.StartProductTask do
  @moduledoc """
  Starts the product stage for an issue, end to end.

  Everything the product stage needs lives here: the task row, the worktree, the
  scratch ticket file the agent reads and writes, the brief describing that file,
  and the spawned run.
  """

  import Rail.Pipeline.Utils.ScratchPath

  alias Rail.Domain.TicketBody
  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.ArgvBuilder
  alias Rail.Runs.PromptBuilder
  alias Rail.Runs.Schemas.RoleRun

  @doc """
  Starts the product stage for `issue`.

  Reuses the issue's existing task when there is one, otherwise creates one at the
  `:product` stage. Returns `{:ok, %{task: task, role_run: role_run, run: run}}`.
  """
  def start_product_task(%Issue{project: %Project{} = project} = issue) do
    with {:ok, task} <- Pipeline.create_task(issue, :product),
         {:ok, %Role{} = role} <- Roles.get_role(project_id: project.id, stage: :product),
         {:ok, worktree_path} <- ensure_worktree(project, task),
         scratch_path = write_scratch(project, task, issue),
         {:ok, role_run} <- Runs.start_or_resume_role_run(task, role, worktree_path) do
      spawn_run(task, project, issue, role, role_run, worktree_path, scratch_path)
    end
  end

  defp ensure_worktree(%Project{} = project, %Task{} = task) do
    case Git.get_or_create_worktree(project, task) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:worktree_failed, reason}}
    end
  end

  defp write_scratch(%Project{} = project, %Task{} = task, %Issue{} = issue) do
    scratch_path = scratch_path(project.id, task.id)
    tickets_dir = Path.join(scratch_path, "tickets")
    File.mkdir_p!(tickets_dir)

    content =
      TicketBody.format(%TicketBody{
        title: issue.title || "",
        description: issue.description || "",
        priority: issue.priority,
        estimate: issue.estimate
      })

    tickets_dir |> Path.join("#{issue.identifier}.md") |> File.write!(content)

    scratch_path
  end

  defp spawn_run(task, project, issue, role, role_run, worktree_path, scratch_path) do
    context =
      [workspace_brief(task, project, worktree_path), brief(issue)]
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

    spawner_opts = [
      backend: role.cli_backend,
      cd: worktree_path,
      scratch_path: scratch_path,
      on_finished: fn _run, outcome -> Pipeline.settle_run(task.id, role_run.id, outcome) end
    ]

    case Runs.start_run(role_run, :stage, argv, spawner_opts) do
      {:ok, run} -> finalize(task, role_run, run)
      {:error, reason} -> fail(task, reason)
    end
  end

  defp brief(%Issue{identifier: identifier}) do
    file = "$RAIL_SCRATCH/tickets/#{identifier}.md"

    String.trim("""
    The ticket is the file #{file}. Rail publishes that file when your run completes cleanly.

    Write it from your worktree with a heredoc, the body and its closing TICKET line at column zero:

    cat > #{file} <<'TICKET'
    ---
    title: <the ticket title>
    priority: urgent | high | medium | low
    estimate: <points>
    ---
    <the ticket body>
    TICKET

    - A heredoc into #{file}, never an inline string.
    - The `---` front matter block starts on the first line of the file. `title` is required; `priority` and `estimate` keep whatever they are already set to when left out.
    - Everything below the closing `---` becomes the ticket body verbatim, and the file replaces the ticket in full.
    - A ticket you split out is its own file, $RAIL_SCRATCH/tickets/split-<n>.md, in this same format. Rail opens each one as a new ticket.
    - These files are the only way to publish a ticket.
    """)
  end

  defp workspace_brief(%Task{} = task, %Project{} = project, worktree_path) do
    base_branch = project.default_branch

    String.trim("""
    Workspace for this task:
    - Worktree: #{worktree_path} (your working directory; every path you touch is under it)
    - Branch: #{task.worktree_name || task.id}, already checked out. Do NOT create a branch of your own, and do not rename this one.
    - Base branch: #{base_branch} on remote `origin`
    - Other agents share this repository. Never switch branches, never work in the main checkout, and never touch another worktree.
    """)
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
end
