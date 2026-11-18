defmodule Rail.Pipeline.Utils.StartWorktreeSetup do
  @moduledoc """
  Runs the project's setup script in a task's worktree before anything else works
  there, so an agent never starts in a checkout that has no ports or database yet.

  Plan is the exception. It reads code and writes before it needs the app, so its agent starts at once and the
  script runs beside it, on the same run, with `start_worktree_setup_beside/1`: the browser waits for the setup
  rather than the plan.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.FailPlanWithoutApp

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

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
      match?(%Run{role: %Role{stage: :plan}}, Repo.preload(run, :role)) -> :not_needed
      true -> start(run, script)
    end
  end

  @doc """
  Starts the setup script beside `run`'s agent, which is already started, if the worktree still needs it and no
  setup is already on its way there. The run is left as the agent has it, unless the setup cannot start: then there
  is no app to design from, so the plan fails, and the message that carries on tries again.

  Returns `:not_needed`, `:already_running` or `{:ok, os_process}`, running or in line, or `{:error, reason}`.
  """
  def start_worktree_setup_beside(%Run{task: %Task{} = task} = run) do
    %Project{worktree_setup_script: script} = Repo.get!(Project, task.project_id)

    cond do
      is_struct(task.worktree_setup_at, DateTime) -> :not_needed
      script in [nil, ""] -> :not_needed
      setup_live?(task) -> :already_running
      true -> start_beside(run, script)
    end
  end

  @doc "True while a setup script runs in `task`'s worktree, or waits in line to."
  def setup_live?(%Task{id: task_id}) do
    Repo.exists?(
      from p in OsProcess,
        where:
          p.task_id == ^task_id and p.kind == :setup and
            p.status in [:waiting_for_resources, :waiting_for_usage, :starting, :running]
    )
  end

  defp start_beside(%Run{} = run, script) do
    case Tools.start_command_process(run, :setup, "./#{script}", timeout_ms: @timeout_ms) do
      {:ok, os_process} ->
        {:ok, os_process}

      {:error, reason} ->
        _error = fail_plan_without_app(run, "The worktree setup script could not start (#{inspect(reason)}).")
        {:error, reason}
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
