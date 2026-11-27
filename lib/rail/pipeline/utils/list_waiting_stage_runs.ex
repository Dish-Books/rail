defmodule Rail.Pipeline.Utils.ListWaitingStageRuns do
  @moduledoc false

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Each task's stage run that waits on a human, in `:project_id` and on issues `:owner_user_id` owns, its task holding
  its runs. Runs are read in a fixed order, so ties between them pick the same stage run on every call.
  """
  def list_waiting_stage_runs(opts) do
    [
      project_id: opts[:project_id],
      owner_user_id: opts[:owner_user_id],
      order_by: [asc: :inserted_at, asc: :id],
      preload: [:role, :questions, task: [:issue, :rounds, :coderabbit_reviews]]
    ]
    |> Pipeline.list_runs()
    |> Enum.group_by(& &1.task_id)
    |> Enum.flat_map(&waiting_stage_run/1)
  end

  defp waiting_stage_run({_task_id, [%Run{task: task} | _rest] = runs}) do
    task = %{task | runs: runs}

    case Task.stage_run(task) do
      %Run{} = run -> if Run.needs_attention?(%{run | task: task}), do: [%{run | task: task}], else: []
      nil -> []
    end
  end
end
