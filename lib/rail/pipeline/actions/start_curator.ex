defmodule Rail.Pipeline.Actions.StartCurator do
  @moduledoc """
  Runs the project's curator on a task marked ready for review, resuming its conversation after the first pass.
  """

  import Rail.Pipeline.Utils.StartRoleRun
  import Rail.Pipeline.Utils.WithTaskLock

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  @doc """
  Starts `task`'s curator pass. Returns `{:ok, run}`, `{:error, :curator_running}` while its curator is mid-turn,
  or `:ok` when there is nothing to start.
  """
  def start_curator(%Task{id: task_id}) do
    task = Task |> Repo.get!(task_id) |> Repo.preload([:project, :issue])

    with %Task{stage: :finalize, marked_ready_at: %DateTime{}, merged_at: nil} <- task,
         {:ok, %Role{} = role} <- Roles.get_role(project_id: task.project_id, stage: :curator) do
      # Outside the lock: transcripts and GitHub would hold up every run finishing on the task.
      dir = Path.join(task.scratch_path, "learnings")
      :ok = Learnings.write_task_files(task, dir)
      File.write!(Path.join(dir, "proposals.md"), proposals_file(task))

      with_task_lock(task_id, fn -> start(task_id, role) end)
    else
      _moved_on_or_unconfigured -> :ok
    end
  end

  defp start(task_id, %Role{} = role) do
    task = Task |> Repo.get!(task_id) |> Repo.preload(runs: :role)

    with %Task{stage: :finalize, marked_ready_at: %DateTime{}, merged_at: nil} <- task,
         false <- Enum.any?(task.runs, &(&1.role_id == role.id and Run.running?(&1))) && {:error, :curator_running} do
      start_role_run(task, role)
    else
      {:error, :curator_running} = running -> running
      _moved_on -> :ok
    end
  end

  defp proposals_file(%Task{} = task) do
    proposals =
      Learnings.list_learning_proposals(
        task_id: task.id,
        project_id: task.project_id,
        statuses: [:pending, :approved, :rejected],
        targets: true
      )

    entries =
      Enum.map(proposals, fn %LearningProposal{} = proposal ->
        target = Enum.map_join(proposal.targets, "", &"\nReplaces #{&1.id}: #{&1.rule}\n")

        """
        ## #{proposal.id} · #{LearningProposal.action_label(proposal.action)} · #{proposal.status}

        #{proposal.title}

        #{proposal.learning.rule}
        #{target}
        """
      end)

    "# Your proposals on this task so far, with how each was decided\n\n" <> Enum.join(entries, "\n")
  end
end
