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
  Where CI stands for `run`, the engineer's or the Review lead's: `nil` for a project without CI or a run whose task
  is gone, or its `state`, the latest CI `os_process`, if any, and its `failures` in a row.

  `:pending` is a commit CI has not passed yet, including one that moved on from
  an earlier pass. `:running` includes CI still in line for its CPUs.
  """
  def get_ci_status(%Run{} = run), do: run |> Repo.preload(task: :project) |> ci_status()

  # A run whose task was just deleted, by Discard or with its issue, has no CI to show.
  defp ci_status(%Run{task: %Task{project: %Project{ci_command: command}} = task} = run) when command not in [nil, ""] do
    latest = List.first(Tools.list_os_processes(run_id: run.id, kind: :ci))
    %{state: state(latest, task), os_process: latest, failures: run.ci_failure_streak}
  end

  defp ci_status(%Run{}), do: nil

  defp state(nil, _task), do: :pending
  defp state(%OsProcess{status: status}, _task) when status in [:waiting_for_resources, :starting, :running], do: :running

  defp state(%OsProcess{exit_code: 0}, %Task{} = task) do
    if ci_passed?(task), do: :passed, else: :pending
  end

  defp state(%OsProcess{}, _task), do: :failed
end
