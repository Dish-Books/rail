defmodule Rail.Pipeline.Utils.SetupRunFinished do
  @moduledoc """
  Where a finished worktree setup leaves its run: carrying on with whatever was
  waiting for it, or failed on what the script said.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
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

      task.stage == role.stage ->
        {:ok, %Run{} = entered} = Pipeline.enter_stage(task, role.stage)
        entered

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

  defp resuming_chat?(%Run{pending_chat: queued}) when queued in [nil, ""], do: false
  defp resuming_chat?(%Run{id: run_id}), do: Tools.list_os_processes(run_id: run_id, kind: :agent) != []
end
