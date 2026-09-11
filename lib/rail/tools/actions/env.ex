defmodule Rail.Tools.Actions.Env do
  @moduledoc false

  import Rail.Tools.Utils.StoredPath

  @doc """
  Builds the environment a tool process should run with: the current
  environment with the tool PATH, plus any extra variables.
  """
  def env(extra \\ %{})

  def env(nil), do: env(%{})

  def env(extra) when is_map(extra) or is_list(extra) do
    base = Map.put(System.get_env(), "PATH", stored_path())

    Enum.reduce(extra, base, fn {key, value}, acc ->
      Map.put(acc, to_string(key), to_string(value))
    end)
  end
end
