defmodule Rail.Pipeline.Actions.StartProductRun do
  @moduledoc """
  Starts the product stage for a task, end to end.

  Everything the product stage needs lives here: the worktree, the scratch ticket
  file the agent reads and writes, the brief describing that file, and the spawned
  run.
  """

  import Rail.Pipeline.Utils.FormatTicket

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs

  @doc """
  Starts the product stage for `task`.

  Returns `{:ok, os_process}` with its `:run` and `:task` loaded.
  """
  def start_product_run(%Task{} = task) do
    %Task{project: %Project{} = project} = task = Repo.preload(task, [:project, :issue])

    write_scratch(task)

    with {:ok, %Role{} = role} <- Roles.get_role(project_id: project.id, stage: :product),
         {:ok, worktree_path} <- ensure_worktree(project, task),
         {:ok, run} <- Runs.start_or_resume_run(task, role, worktree_path) do
      spawn_os_process(task, role, run, worktree_path)
    end
  end

  defp ensure_worktree(%Project{} = project, %Task{} = task) do
    case Git.get_or_create_worktree(project, task) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:worktree_failed, reason}}
    end
  end

  defp write_scratch(%Task{issue: issue, scratch_path: scratch_path}) do
    tickets_dir = Path.join(scratch_path, "tickets")
    File.mkdir_p!(tickets_dir)

    tickets_dir |> Path.join("#{issue.identifier}.md") |> File.write!(format_ticket(issue))
  end

  defp spawn_os_process(task, role, run, worktree_path) do
    prompt =
      Runs.build_prompt(
        task: task,
        backend: role.backend,
        role_instructions: role.system_prompt,
        context_snippet: brief(task),
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

    Runs.start_os_process(run, args)
  end

  defp brief(%Task{scratch_path: scratch_path} = task) do
    file = "#{scratch_path}/tickets/#{identifier(task)}.md"

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
    - This file is the only way to publish a ticket.
    """)
  end

  defp identifier(%Task{issue: %Issue{identifier: identifier}}), do: identifier
  defp identifier(%Task{id: id}), do: id
end
