defmodule Rail.Pipeline.Utils.BroadcastPipelineChanged do
  @moduledoc """
  Says on `"pipeline"` that a task's stage or its run changed, for the Overview to reload.
  """

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Broadcasts `{:pipeline_changed, task_id}` and returns what it was given, so it drops into a pipe.
  """
  def broadcast_pipeline_changed(%Task{id: task_id} = task) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "pipeline", {:pipeline_changed, task_id})
    task
  end

  def broadcast_pipeline_changed(%Run{task_id: task_id} = run) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "pipeline", {:pipeline_changed, task_id})
    run
  end
end
