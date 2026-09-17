defmodule Rail.Pipeline.Utils.SendBack do
  @moduledoc """
  Writes what a stage is being handed onto that stage's own log.

  A stage is told things two ways and neither of them is readable afterwards: a
  brief, which is built at spawn and thrown away, and a pending answer, which the
  spawn consumes. So a stage that has run before starts working again with
  nothing in its conversation saying why, and nobody reading it can tell what it
  was asked to do.

  Nothing is written for a stage that has never run: its first turn is the brief,
  and there is no conversation yet for this to be the next thing in.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  @doc """
  Records `note` on the log of `task`'s run at `stage`.

  Tagged as the human's, because it is: a person decided this stage should look
  at the change again.
  """
  def send_back(%Task{} = task, stage, note) when is_atom(stage) and is_binary(note) do
    with {:ok, %Role{id: role_id}} <- Roles.get_role(project_id: task.project_id, stage: stage),
         %Run{} = run <- Repo.get_by(Run, task_id: task.id, role_id: role_id) do
      lines = note |> String.trim() |> String.split("\n") |> Enum.map(&"[human] #{&1}")
      Pipeline.append_run_events(run.id, nil, lines)
    else
      _never_run -> :ok
    end
  end
end
