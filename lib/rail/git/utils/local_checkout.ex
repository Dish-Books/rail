defmodule Rail.Git.Utils.LocalCheckout do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task

  @doc """
  The path of `task`'s checkout when it is on Rail's own disk, as it is only under the `:local` runtime, or nil. Its
  `.git` is a file in a task still on a worktree of its project's clone.
  """
  def local_checkout(%Task{worktree_path: path}) when is_binary(path) do
    if Rail.sandbox_runtime() == :local and File.exists?(Path.join(path, ".git")), do: path
  end
end
