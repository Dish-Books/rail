defmodule Rail.Runs.Utils.OnOsProcessFinished do
  @moduledoc false

  @doc """
  Callback invoked when a run completes execution.
  """
  def on_os_process_finished(os_process, outcome) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "os_processes", {:os_process_finished, os_process, outcome})
    {:ok, outcome}
  end
end
