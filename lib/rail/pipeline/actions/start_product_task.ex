defmodule Rail.Pipeline.Actions.StartProductTask do
  @moduledoc """
  Starts the product stage for an issue, end to end.

  Everything the product stage needs lives here: the task row, the worktree, the
  scratch ticket file the agent reads and writes, the brief describing that file,
  and the spawned run.
  """

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
  alias Rail.Runs.Schemas.Run

  @doc """
  Starts the product stage for `issue`.

  Reuses the issue's existing task when there is one, otherwise creates one at the
  `:product` stage. Returns `{:ok, %{task: task, run: run, os_process: os_process}}`.
  """
  def start_product_task(%Issue{project: %Project{} = project} = issue, opts \\ []) do
    with {:ok, task} <- Pipeline.create_task(issue, :product),
         {:ok, %Role{} = role} <- Roles.get_role(project_id: project.id, stage: :product),
         {:ok, worktree_path} <- ensure_worktree(project, task),
         _scratch = write_scratch(task, issue),
         {:ok, run} <- Runs.start_or_resume_run(task, role, worktree_path) do
      spawn_os_process(task, issue, role, run, worktree_path, opts)
    end
  end

  defp ensure_worktree(%Project{} = project, %Task{} = task) do
    case Git.get_or_create_worktree(project, task) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:worktree_failed, reason}}
    end
  end

  defp write_scratch(%Task{scratch_path: scratch_path}, %Issue{} = issue) do
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

  defp spawn_os_process(task, issue, role, run, worktree_path, opts) do
    prompt =
      Runs.build_prompt(
        task: task,
        backend: role.backend,
        role_instructions: role.system_prompt,
        context_snippet: brief(issue, task.scratch_path),
        pending_answer: run.pending_answer,
        conversation_id: run.conversation_id
      )

    args =
      Runs.build_args(
        backend: role.backend,
        prompt: prompt,
        model: role.model,
        reasoning_effort: role.reasoning_effort || "high",
        system_prompt: role.system_prompt,
        conversation_id: run.conversation_id,
        work_dir: worktree_path
      )

    spawner_opts =
      [on_finished: fn os_process, outcome -> Pipeline.settle_product_run(os_process, outcome) end] ++
        Keyword.take(opts, [:allow_fun])

    case Runs.start_os_process(run, :stage, args, spawner_opts) do
      {:ok, os_process} -> finalize(task, run, os_process)
      {:error, reason} -> fail(task, reason)
    end
  end

  defp brief(%Issue{identifier: identifier}, scratch_path) do
    file = "#{scratch_path}/tickets/#{identifier}.md"

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
    - A ticket you split out is its own file, #{scratch_path}/tickets/split-<n>.md, in this same format. Rail opens each one as a new ticket.
    - These files are the only way to publish a ticket.
    """)
  end

  defp finalize(task, run, os_process) do
    {:ok, run} =
      run
      |> Run.changeset(%{pending_answer: nil, attempt_log_lines: 0})
      |> Repo.update()

    {:ok, task} = task |> Task.changeset(%{stage_state: :running}) |> Repo.update()

    Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :dispatched})

    {:ok, %{task: task, run: run, os_process: os_process}}
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
