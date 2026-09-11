defmodule Rail.Tools.Utils.ResolveCache do
  @moduledoc """
  Node-wide memoization of executable lookups, keyed by the PATH they were
  resolved against so a changed PATH never returns a stale hit.
  """

  @cache_term {__MODULE__, :cache}

  @doc """
  Returns the cached resolution for `executable` under `path`, computing and
  storing it on a miss.
  """
  def fetch(path, executable, compute) when is_function(compute, 0) do
    cache = :persistent_term.get(@cache_term, %{})
    key = {path, executable}

    case Map.fetch(cache, key) do
      {:ok, resolved} ->
        resolved

      :error ->
        resolved = compute.()
        :persistent_term.put(@cache_term, Map.put(cache, key, resolved))
        resolved
    end
  end
end
