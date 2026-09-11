defmodule Rail.Tools.Actions.Resolve do
  @moduledoc false

  import Rail.Tools.Utils.ResolveCache
  import Rail.Tools.Utils.StoredPath

  @separator ":"

  @doc """
  Resolves an executable to its absolute path on the tool PATH.

  Names that already contain a `/` are returned as given. Falls back to the
  bare name when nothing on PATH matches.
  """
  def resolve(executable) when is_binary(executable) do
    if String.contains?(executable, "/") do
      executable
    else
      path = stored_path()
      fetch(path, executable, fn -> scan(path, executable) end)
    end
  end

  defp scan(path, executable) do
    path
    |> String.split(@separator)
    |> Enum.find_value(executable, fn dir ->
      candidate = Path.join(dir, executable)
      if executable?(candidate), do: candidate
    end)
  end

  defp executable?(candidate) do
    case File.stat(candidate) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        Bitwise.band(mode, 0o111) != 0

      _other ->
        false
    end
  end
end
