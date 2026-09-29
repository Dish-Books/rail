defmodule Rail.Roles.Utils.SandboxCapacity do
  @moduledoc false

  alias Rail.Tools

  @doc """
  What this machine can reserve, for a role's reservation to be checked against,
  or nil when Docker cannot be asked. The line refuses what never fits either way.
  """
  def sandbox_capacity do
    case Tools.get_sandbox_capacity() do
      {:ok, capacity} -> capacity
      {:error, _reason} -> nil
    end
  end
end
