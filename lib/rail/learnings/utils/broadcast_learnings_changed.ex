defmodule Rail.Learnings.Utils.BroadcastLearningsChanged do
  @moduledoc """
  Says on `"learnings"` that a project's rules or proposals changed, for an open page to reload.
  """

  @doc """
  Broadcasts `{:learnings_changed, project_id}`. Call it after the write commits.
  """
  def broadcast_learnings_changed(project_id) when is_binary(project_id) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "learnings", {:learnings_changed, project_id})
  end
end
