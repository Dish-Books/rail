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
    task = Task |> Repo.get!(task_id) |> Repo.preload([:project, :issue, :runs])

    with %Task{stage: :finalize, marked_ready_at: %DateTime{}, merged_at: nil} <- task,
         {:ok, %Role{} = role} <- Roles.get_role(project_id: task.project_id, stage: :curator),
         # Before the files: a turn mid-read keeps them, and the job waits without calling GitHub.
         false <- curator_running?(task, role) && {:error, :curator_running} do
      # Outside the lock: transcripts and GitHub would hold up every run finishing on the task.
      dir = Path.join(task.scratch_path, "learnings")
      :ok = Learnings.write_task_files(task, dir)
      File.write!(Path.join(dir, "proposals.md"), proposals_file(task))

      with_task_lock(task_id, fn -> start(task_id, role) end)
    else
      {:error, :curator_running} = running -> running
      _moved_on_or_unconfigured -> :ok
    end
  end

  defp start(task_id, %Role{} = role) do
    task = Task |> Repo.get!(task_id) |> Repo.preload(runs: :role)

    with %Task{stage: :finalize, marked_ready_at: %DateTime{}, merged_at: nil} <- task,
         false <- curator_running?(task, role) && {:error, :curator_running} do
      # The task was marked ready, so a conversation it resumes is told the task came back.
      start_role_run(task, role, new_pass: true)
    else
      {:error, :curator_running} = running -> running
      _moved_on -> :ok
    end
  end

  defp curator_running?(%Task{runs: runs}, %Role{id: role_id}),
    do: Enum.any?(runs, &(&1.role_id == role_id and Run.running?(&1)))

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
