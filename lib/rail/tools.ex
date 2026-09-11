defmodule Rail.Tools do
  @moduledoc """
  Public context for running external CLI tools with login-shell PATH parity.
  """

  alias Rail.Tools.Actions

  defdelegate run(executable, args, opts \\ []), to: Actions.Run
  defdelegate resolve(executable), to: Actions.Resolve
  defdelegate env(extra \\ %{}), to: Actions.Env
end
