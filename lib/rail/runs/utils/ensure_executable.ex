defmodule Rail.Runs.Utils.EnsureExecutable do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run

  @doc """
  Confirms the backend's executable is a real file before anything is spawned.

  The path comes from the backend row and is absolute, so there is nothing to
  resolve — it either exists or the run is over. When it is missing, the run and
  its run are settled as failed and `{:error, {:missing_binary, path, run}}`
  is returned for the caller to pass on.
  """
  def ensure_executable(executable, %OsProcess{} = os_process, %Run{} = run) do
    if File.exists?(executable) and not File.dir?(executable) do
      :ok
    else
      settle_missing_binary(executable, os_process, run)
    end
  end

  defp settle_missing_binary(executable, os_process, run) do
    error_msg = "No such CLI binary: #{executable}"

    updated_run =
      os_process
      |> OsProcess.changeset(%{status: :finished})
      |> Repo.update!()

    run
    |> Run.changeset(%{
      status: :finished,
      completed_at: DateTime.utc_now(),
      exit_code: -1,
      error: error_msg
    })
    |> Repo.update!()

    {:error, {:missing_binary, executable, updated_run}}
  end
end
