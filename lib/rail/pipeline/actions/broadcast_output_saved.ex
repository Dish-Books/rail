defmodule Rail.Pipeline.Actions.BroadcastOutputSaved do
  @moduledoc """
  Tells every page open on a task that one of its outputs was saved; per task, so
  a page hears only its own task's saves and the Overview does not reload.
  """

  alias Rail.Pipeline.Schemas.Task

  @doc """
  Broadcasts `{:output_saved, task_id}` on `"outputs:<task_id>"` and returns `:ok`.
  """
  def broadcast_output_saved(%Task{id: task_id}) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "outputs:#{task_id}", {:output_saved, task_id})
  end
end
