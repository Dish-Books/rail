defmodule Rail.Pipeline.Actions.GetCiStatus do
  @moduledoc false

  import Rail.Pipeline.Utils.CiPassed

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Where CI stands for the engineer's `run`: `nil` for a project without CI, or
  its `state` and the latest CI `os_process`, if any.

  `:pending` is a commit CI has not passed yet, including one that moved on from
  an earlier pass.
  """
  def get_ci_status(%Run{} = run) do
    %Run{task: %Task{project: %Project{ci_command: command}} = task} = Repo.preload(run, task: :project)

    if command in [nil, ""] do
      nil
    else
      latest = List.first(Tools.list_os_processes(run_id: run.id, kind: :ci))
      %{state: state(latest, task), os_process: latest, failures: run.ci_failure_streak}
    end
  end

  defp state(nil, _task), do: :pending
  defp state(%OsProcess{status: status}, _task) when status in [:starting, :running], do: :running

  defp state(%OsProcess{exit_code: 0}, %Task{} = task) do
    if ci_passed?(task), do: :passed, else: :pending
  end

  defp state(%OsProcess{}, _task), do: :failed
end
