defmodule Rail.Pipeline.Actions.RunCi do
  @moduledoc """
  Runs CI on the engineer's latest commit because a person asked to.

  Asking is stepping in, so the count of failures sent back on their own starts
  over.
  """

  import Rail.Pipeline.Utils.StartCi

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Starts CI on `run`, the engineer's. Returns `{:ok, run}` with CI running.
  """
  def run_ci(%Scope{}, %Run{} = run) do
    run = Repo.preload(run, [task: :project, role: :backend], force: true)

    with :ok <- runnable(run) do
      {:ok, reset} = run |> Run.changeset(%{ci_failure_streak: 0}) |> Repo.update()

      case start_ci(reset) do
        {:ok, os_process} -> {:ok, os_process.run}
        {:error, %Run{error: error}} -> {:error, error}
      end
    end
  end

  defp runnable(%Run{task: %Task{project: %Project{ci_command: command}} = task} = run) do
    cond do
      command in [nil, ""] -> {:error, :no_ci_command}
      Run.running?(run) -> {:error, :stage_running}
      Git.worktree_dirty?(task.worktree_path) -> {:error, :uncommitted_changes}
      true -> :ok
    end
  end
end
