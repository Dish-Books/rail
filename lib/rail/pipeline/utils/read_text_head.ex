defmodule Rail.Pipeline.Utils.ReadTextHead do
  @moduledoc false

  @doc """
  Reads up to `limit` bytes of `path` as `{:text, text, truncated?}` when they
  are UTF-8 with no NUL in them, or `:binary` when they are not.
  """
  def read_text_head(path, limit) do
    read =
      File.open!(path, [:read, :binary], fn device ->
        case IO.binread(device, limit + 1) do
          data when is_binary(data) -> data
          :eof -> ""
        end
      end)

    truncated = byte_size(read) > limit

    # The limit is in bytes, so it can land inside a character; half of one at
    # the cut is the limit's doing rather than the file's.
    case :unicode.characters_to_binary(binary_part(read, 0, min(byte_size(read), limit))) do
      text when is_binary(text) -> text(text, truncated)
      {:incomplete, text, _cut} when truncated -> text(text, truncated)
      _not_utf8 -> :binary
    end
  end

  defp text(text, truncated) do
    if String.contains?(text, <<0>>), do: :binary, else: {:text, text, truncated}
  end
end
