defmodule Rail.Pipeline.Actions.GetCiStatus do
  @moduledoc false

  import Rail.Pipeline.Utils.CiPassed

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  # Enough of the log to see what is running or what failed, small enough to sit above a list.
  @tail_lines 12

  @doc """
  Where CI stands for `run`, the engineer's or the Review lead's: `nil` for a project without CI, or its
  `state`, the latest CI `os_process`, if any, its `failures` in a row, and `tail`, the end of its log
  while it runs or once it has failed.

  `:pending` is a commit CI has not passed yet, including one that moved on from
  an earlier pass.
  """
  def get_ci_status(%Run{} = run) do
    %Run{task: %Task{project: %Project{ci_command: command}} = task} = Repo.preload(run, task: :project)

    if command in [nil, ""] do
      nil
    else
      latest = List.first(Tools.list_os_processes(run_id: run.id, kind: :ci))
      state = state(latest, task)

      %{
        state: state,
        os_process: latest,
        failures: run.ci_failure_streak,
        tail: if(state in [:running, :failed], do: tail(latest), else: [])
      }
    end
  end

  defp state(nil, _task), do: :pending
  defp state(%OsProcess{status: status}, _task) when status in [:starting, :running], do: :running

  defp state(%OsProcess{exit_code: 0}, %Task{} = task) do
    if ci_passed?(task), do: :passed, else: :pending
  end

  defp state(%OsProcess{}, _task), do: :failed

  defp tail(%OsProcess{stream_path: stream_path}) do
    case File.read(stream_path) do
      {:ok, output} -> output |> Tools.plain_text() |> String.split("\n") |> trailing()
      {:error, _missing} -> []
    end
  end

  defp trailing(lines) do
    lines |> Enum.reverse() |> Enum.drop_while(&(String.trim(&1) == "")) |> Enum.take(@tail_lines) |> Enum.reverse()
  end
end
