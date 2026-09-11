defmodule Rail.Tools.Utils.StoredPath do
  @moduledoc """
  Memoizes the merged tool PATH for the node, probing the login shell the first
  time it is asked.
  """

  import Rail.Tools.Utils.LoginShellPath
  import Rail.Tools.Utils.MergedPath

  @path_term {__MODULE__, :path}

  @doc """
  Returns the merged tool PATH, computing and storing it on the first call.
  """
  def stored_path do
    case :persistent_term.get(@path_term, nil) do
      path when is_binary(path) ->
        path

      nil ->
        merged = merged_path(login_shell_path())
        :persistent_term.put(@path_term, merged)
        merged
    end
  end
end
