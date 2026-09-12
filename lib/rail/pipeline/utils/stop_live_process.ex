defmodule Rail.Pipeline.Utils.StopLiveProcess do
  @moduledoc """
  Kills whatever OS process is carrying a run, if one is.
  """

  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run

  @doc """
  Stops `run`'s live OS process and returns `:ok`, whether or not there was one.
  """
  def stop_live_process(%Run{} = run, opts \\ []) do
    case Runs.get_active_os_process(run) do
      %OsProcess{} = os_process -> Runs.stop_os_process(os_process, opts)
      nil -> :ok
    end

    :ok
  end
end
