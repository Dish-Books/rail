defmodule Rail.Pipeline.Utils.StartCi do
  @moduledoc """
  Runs the project's CI command against the commit the engineer's worktree is on.

  It gets the same credentials Rail pushes with, since a CI that records its
  result somewhere, as a pushed ref, has to be able to reach the remote.
  """

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools

  @doc """
  Starts CI on `run`. Returns `{:ok, os_process}`, or `{:error, run}` with the run
  failed on why it could not start.
  """
  def start_ci(%Run{task: %Task{} = task} = run) do
    %Project{} = project = Repo.get!(Project, task.project_id)
    {:ok, running} = run |> Run.changeset(%{status: :running, error: nil, exit_code: nil}) |> Repo.update()

    opts = [
      timeout_ms: to_timeout(minute: project.ci_timeout_minutes),
      head_sha: Git.branch_fingerprint(task.worktree_path)[:head_sha]
    ]

    with {:ok, env} <- Git.credential_env(project),
         {:ok, os_process} <- Tools.start_command_process(running, :ci, project.ci_command, [{:env, env} | opts]) do
      {:ok, os_process}
    else
      {:error, reason} ->
        attrs = %{status: :finished, error: "Could not start CI: #{inspect(reason)}"}
        {:ok, failed} = running |> Run.changeset(attrs) |> Repo.update()
        {:error, failed}
    end
  end
end
