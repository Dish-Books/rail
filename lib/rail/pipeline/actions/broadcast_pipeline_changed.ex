defmodule Rail.Pipeline.Actions.BroadcastPipelineChanged do
  @moduledoc false

  @topic "pipeline:changed"

  @doc """
  Broadcasts a `{:pipeline_changed, meta}` event on the `"pipeline:changed"` PubSub topic.
  """
  def broadcast_pipeline_changed(meta \\ %{}) do
    Phoenix.PubSub.broadcast(Rail.PubSub, @topic, {:pipeline_changed, meta})
  end
end
