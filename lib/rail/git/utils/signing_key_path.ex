defmodule Rail.Git.Utils.SigningKeyPath do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task

  @doc """
  Where a turn's signing key sits while the agent commits: under the task's scratch folder, which the
  agent's sandbox sees and the commit never holds. The public half is beside it, as git wants.
  """
  def signing_key_path(%Task{scratch_path: scratch_path}), do: Path.join([scratch_path, ".signing", "key"])
end
