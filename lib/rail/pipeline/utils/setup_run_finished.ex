defmodule Rail.Pipeline.Utils.SetupRunFinished do
  @moduledoc """
  Where a finished worktree setup leaves its run: carrying on with whatever was
  waiting for it, or failed on what the script said.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.StartRoleRun

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools

  @doc "Finishes `run` after its worktree setup script exited."
  def setup_run_finished(%Run{exit_code: 0, task: %Task{} = task, role: %Role{} = role} = run, _opts) do
    {:ok, task} = task |> Task.changeset(%{worktree_setup_at: DateTime.utc_now()}) |> Repo.update()
    run = %{run | task: task}

    # A message queued on a conversation already under way is drained once this
    # returns; anything else was held up on its way into the stage.
    cond do
      resuming_chat?(run) ->
        run

      Task.role_stage(task.stage) == role.stage ->
        {:ok, %Run{} = entered} = Pipeline.enter_stage(task, task.stage)

        entered

      # The checks wait on the first one's setup, so it starts them once the worktree is ready.
      task.stage == :review and role.stage in Task.check_stages() ->
        start_checks_held(task, role, run)

      true ->
        run
    end
  end

  def setup_run_finished(%Run{} = run, _opts) do
    why = run.error || "exit #{run.exit_code}"
    error = "The worktree setup script failed (#{why}). Its output is above; once what it reports is fixed, retry."

    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end

  # A retried check whose setup ran restarts only itself, since a sibling that already has a run is under way.
  defp start_checks_held(%Task{} = task, %Role{} = role, %Run{} = run) do
    {:ok, %Role{} = own} = Roles.get_role(id: role.id)
    {:ok, %Run{}} = start_role_run(task, own, fresh: true)

    begun = Repo.all(from r in Run, join: role in assoc(r, :role), where: r.task_id == ^task.id, select: role.stage)

    for stage <- (Task.check_stages() ++ asked(Pipeline.read_plan(task))) -- [role.stage | begun],
        {:ok, %Role{} = sibling} <- [Roles.get_role(project_id: task.project_id, stage: stage)] do
      {:ok, %Run{}} = start_role_run(task, sibling, fresh: true)
    end

    run |> Repo.reload!() |> Repo.preload([:task, :role])
  end

  # A demo is recorded only when the round's plan asks.
  defp asked(%Round{record_demo: true}), do: [:demo]
  defp asked(_round), do: []

  defp resuming_chat?(%Run{pending_chat: queued}) when queued in [nil, ""], do: false
  defp resuming_chat?(%Run{id: run_id}), do: Tools.list_os_processes(run_id: run_id, kind: :agent) != []
end
