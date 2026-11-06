defmodule Rail.Pipeline.Utils.WithTaskLock do
  @moduledoc false

  @doc """
  Runs `fun` while nothing else holding the task's lock does: Discard and Back to Plan, a run finishing, a queued
  engineer start, a message going out and a Retry. Not counted per holder, so nothing under it may take it again.
  """
  def with_task_lock(task_id, fun) when is_binary(task_id) and is_function(fun, 0) do
    :global.trans({{__MODULE__, task_id}, self()}, fun, [node()], :infinity)
  end
end
