defmodule Rail.Pipeline.Actions.StartDesignTask do
  @moduledoc """
  Starts the design stage for a task, end to end.

  Everything the design stage needs lives here: the worktree, the scratch tree the
  agent reads its ticket from and writes its directions into, the brief describing
  both, and the spawned run.
  """

  alias Rail.Domain.TicketBody
  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs

  @doc """
  Starts the design stage for `task_or_id`.

  Moves the task to the `:design` stage, reusing the worktree it already has, and
  spawns the design role against the approved ticket. Returns
  `{:ok, os_process}` with its `:run` and `:task` loaded.
  """
  def start_design_task(task_or_id) do
    with %Task{project: %Project{} = project} = task <- resolve_task(task_or_id),
         {:ok, %Role{} = role} <- Roles.get_role(project_id: project.id, stage: :design),
         {:ok, worktree_path} <- ensure_worktree(project, task),
         {:ok, task} <- claim_stage(task, worktree_path),
         _scratch = write_scratch(task),
         {:ok, run} <- Runs.start_or_resume_run(task, role, worktree_path) do
      spawn_os_process(task, role, run, worktree_path)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # The worktree and the scratch tree

  defp ensure_worktree(%Project{} = project, %Task{} = task) do
    case Git.get_or_create_worktree(project, task) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:worktree_failed, reason}}
    end
  end

  defp claim_stage(%Task{} = task, worktree_path) do
    task
    |> Task.changeset(%{stage: :design, worktree_path: worktree_path, retry_after: nil, error: nil})
    |> Repo.update()
  end

  defp write_scratch(%Task{scratch_path: scratch_path} = task) do
    File.mkdir_p!(Path.join(scratch_path, "design"))

    case task.issue do
      %Issue{} = issue ->
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

      nil ->
        :ok
    end

    scratch_path
  end

  defp brief(%Task{scratch_path: scratch_path} = task) do
    ticket_line =
      case task.issue do
        %Issue{identifier: identifier} ->
          "The ticket you are designing for is the file #{scratch_path}/tickets/#{identifier}.md. It is not yours to edit.\n\n"

        nil ->
          ""
      end

    String.trim("""
    #{ticket_line}Produce three distinct design directions on a single published canvas, and never edit application code on this stage.

    Rail reads the directions from #{scratch_path}/design/. Save a still screenshot of each one there, and write the manifest to #{scratch_path}/design/manifest.json with this shape:
    {
      "canvasUrl": "<absolute https URL to the published canvas>",
      "version": 1,
      "directions": [
        {
          "key": "<unique-key>",
          "title": "<title of direction>",
          "notes": "<notes on what it does differently>",
          "stillPath": "#{scratch_path}/design/<still>.png"
        }
      ],
      "pickedKey": null
    }

    A human picks one of the directions before anything is planned. Stop once the canvas is published, the stills are captured and the manifest is written.
    """)
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

    argv =
      Runs.build_args(
        backend: role.backend,
        prompt: prompt,
        model: role.model,
        reasoning_effort: role.reasoning_effort || "high",
        system_prompt: role.system_prompt,
        conversation_id: run.conversation_id,
        work_dir: worktree_path
      )

    Runs.start_os_process(run, argv)
  end

  # The project and the issue are carried on the task from here on: every step below
  # needs them, and none of them should be refetching either.
  defp resolve_task(%Task{} = task), do: Repo.preload(task, [:project, :issue])
  defp resolve_task(id) when is_binary(id), do: Task |> Repo.get(id) |> resolve_task()
  defp resolve_task(_other), do: nil
end
