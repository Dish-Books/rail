defmodule Rail.Pipeline.Actions.ListWaits do
  @moduledoc false

  import Rail.Pipeline.Utils.ListWaitingStageRuns

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @doc """
  What waits on each task's owner now, in `:project_id` and on issues `:owner_user_id` owns, oldest first: each as its
  run, `:kind` (`:questions`, `:review` or `:failed`), `:id` and `:since`. A run that stopped without a verdict is none.
  """
  def list_waits(opts \\ []) do
    [project_id: opts[:project_id], owner_user_id: opts[:owner_user_id]]
    |> list_waiting_stage_runs()
    |> Enum.flat_map(&wait/1)
    |> Enum.sort_by(&{DateTime.to_unix(&1.since, :microsecond), &1.id})
  end

  defp wait(%Run{task: %Task{} = task} = run) do
    state = Run.state(run)

    newest_unsent =
      run.questions
      |> Enum.filter(&is_nil(&1.delivered_at))
      |> Enum.max_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id}, fn -> nil end)

    cond do
      # A turn that fails after asking reads failed until its round is registered, so its questions name it either way.
      state in [:blocked, :failed] and is_struct(newest_unsent, Question) ->
        [%{run: run, kind: :questions, id: "#{run.id}:#{newest_unsent.id}", since: newest_unsent.inserted_at}]

      # Its answers are sent and the agent is about to take them.
      state == :blocked ->
        []

      state == :done ->
        [stamped(run, :review)]

      state == :failed ->
        [stamped(run, :failed)]

      task.stage == :custom and Enum.any?(Pipeline.read_stage_outputs(task), &(&1.name == task.custom_stage)) ->
        [stamped(run, :review)]

      true ->
        []
    end
  end

  # A run the old code settled during a deploy, after the backfill, takes the backfill's value until it is stamped.
  defp stamped(%Run{} = run, kind) do
    at = run.wait_started_at || run.completed_at || run.updated_at
    %{run: run, kind: kind, id: "#{run.id}:#{DateTime.to_unix(at, :microsecond)}", since: at}
  end
end
