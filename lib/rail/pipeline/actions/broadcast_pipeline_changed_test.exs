defmodule Rail.Pipeline.Actions.BroadcastPipelineChangedTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline

  test "broadcasts pipeline_changed event with default and custom meta" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    assert :ok = Pipeline.broadcast_pipeline_changed()
    assert_receive {:pipeline_changed, %{}}

    custom_meta = %{task_id: "tsk_123", event: :custom}
    assert :ok = Pipeline.broadcast_pipeline_changed(custom_meta)
    assert_receive {:pipeline_changed, ^custom_meta}
  end
end
