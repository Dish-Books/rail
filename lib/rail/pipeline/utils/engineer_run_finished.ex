defmodule Rail.Pipeline.Utils.EngineerRunFinished do
  @moduledoc """
  Where a finished engineer run leaves its task.

  The engineer says it is finished by calling `commit`, or asks for the default
  branch with `request_merge`, and either call stops the turn on the spot and
  hands the work to Rail. A stopped turn applies no finish, so the only turn that
  reaches here is one that ended on its own without calling either, and that is
  recorded on the run so the stage stays open for the message that fixes it.
  """

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

  @doc "Finishes `run` as the engineer stage."
  def engineer_run_finished(%Run{} = run, _opts) do
    {:ok, failed} = run |> Run.changeset(%{error: "The engineer did not commit its work."}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end
