defmodule Rail.Pipeline.Utils.StopLiveProcess do
  @moduledoc """
  Kills whatever OS process is carrying a run, if one is.
  """

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Stops `run`'s live OS process and returns `:ok`, whether or not there was one.
  """
  def stop_live_process(%Run{} = run, opts \\ []) do
    case Tools.get_active_os_process(run) do
      {:ok, %OsProcess{} = os_process} -> Tools.stop_os_process(os_process, opts)
      {:error, :os_process_not_active} -> :ok
    end

    :ok
  end
end
