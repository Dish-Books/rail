defmodule Rail.Runs.Utils.DrainErrFile do
  @moduledoc false

  import Rail.Runs.Utils.DecodeUtf8Lenient

  @doc """
  Reads the stderr file if present, as trimmed non-empty lines.
  """
  def drain_err_file(err_path) do
    with true <- File.exists?(err_path),
         {:ok, content} <- File.read(err_path) do
      content
      |> decode_utf8_lenient()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    else
      _missing_or_unreadable -> []
    end
  end
end
