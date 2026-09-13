defmodule Rail.Tools.Actions.ConnectPort do
  @moduledoc false

  @doc """
  Hands a spawned port off to `owner` and unlinks it from the caller, so the
  caller can exit without taking the child down.

  Any exit status that already arrived is forwarded to the new owner. Passing
  `nil` releases the port without reassigning it.
  """
  # coveralls-ignore-start (defensive rescue if the port terminates mid-handoff)
  def connect_port(port, owner) when is_pid(owner) do
    try do
      Port.connect(port, owner)
      Process.unlink(port)
    rescue
      _error -> :ok
    end

    receive do
      {^port, {:exit_status, status}} ->
        send(owner, {port, {:exit_status, status}})
    after
      0 -> :ok
    end

    :ok
  end

  def connect_port(port, nil) do
    Process.unlink(port)
    :ok
  rescue
    _error -> :ok
  end

  # coveralls-ignore-stop
end
