defmodule Rail.Pipeline.Utils.StartWorktreeSetup do
  @moduledoc """
  Runs the project's setup script in a task's worktree before anything else works
  there, so an agent never starts in a checkout that has no ports or database yet.
  """

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools

  @timeout_ms to_timeout(minute: 30)

  @doc """
  Starts the setup script on `run` if its task's worktree still needs it.

  Returns `:not_needed`, `{:ok, os_process}` with the script running, or
  `{:error, run}` with the run failed on why it could not start.
  """
  def start_worktree_setup(%Run{task: %Task{} = task} = run) do
    %Project{worktree_setup_script: script} = Repo.get!(Project, task.project_id)

    cond do
      is_struct(task.worktree_setup_at, DateTime) -> :not_needed
      script in [nil, ""] -> :not_needed
      true -> start(run, script)
    end
  end

  defp start(%Run{} = run, script) do
    {:ok, running} = run |> Run.changeset(%{status: :running, error: nil, exit_code: nil}) |> Repo.update()

    case Tools.start_command_process(running, :setup, "./#{script}", timeout_ms: @timeout_ms) do
      {:ok, os_process} ->
        {:ok, os_process}

      {:error, reason} ->
        attrs = %{status: :failed, error: "Could not start the worktree setup script: #{inspect(reason)}"}
        {:ok, failed} = running |> Run.changeset(attrs) |> Repo.update()
        {:error, failed}
    end
  end
end
