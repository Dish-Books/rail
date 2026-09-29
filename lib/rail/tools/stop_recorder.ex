defmodule Rail.Tools.StopRecorder do
  @moduledoc """
  Records when Rail goes down, so the restart that follows can say how long it
  was away. It traps exits, so it hears the tree stopping and writes as it goes.
  """
  use GenServer

  alias Rail.Repo
  alias Rail.Tools.Schemas.Restart

  @doc """
  Starts the recorder in the supervision tree, unless adoption on boot is off,
  since then no restart is ever recorded to pair it with.
  """
  def start_link(_opts) do
    if Application.get_env(:rail, :adopt_on_boot, true), do: GenServer.start_link(__MODULE__, :ok), else: :ignore
  end

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state) do
    %Restart{} |> Restart.changeset(%{stopped_at: DateTime.utc_now()}) |> Repo.insert!()
    :ok
  end
end
