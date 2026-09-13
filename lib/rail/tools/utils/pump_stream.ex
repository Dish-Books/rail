defmodule Rail.Tools.Utils.PumpStream do
  @moduledoc false

  import Rail.Tools.Utils.DecodeUtf8Lenient

  @doc """
  Reads new bytes appended to the stream file, splits on newline, and yields complete lines.

  A trailing fragment is held back as the partial line until the writer finishes it,
  unless `final: true` says the writer is gone and the fragment is all there is.
  """
  def pump_stream(stream_path, file_offset, partial_line, opts \\ []) do
    case File.stat(stream_path) do
      {:ok, %File.Stat{size: size}} when size > file_offset ->
        read_stream_bytes(stream_path, file_offset, size, partial_line, opts)

      _missing_or_unwritten ->
        finalize_partial_line(partial_line, file_offset, opts)
    end
  end

  defp read_stream_bytes(stream_path, file_offset, size, partial_line, opts) do
    case File.open(stream_path, [:read, :binary]) do
      {:ok, handle} ->
        :file.position(handle, file_offset)
        result = :file.read(handle, size - file_offset)
        File.close(handle)
        split_lines(result, size, file_offset, partial_line, opts)

      # coveralls-ignore-start (defensive file open error fallback)
      _open_error ->
        {[], file_offset, partial_line}
        # coveralls-ignore-stop
    end
  end

  defp split_lines({:ok, bytes}, size, _file_offset, partial_line, opts) do
    parts = :binary.split(partial_line <> bytes, "\n", [:global])
    {complete_lines, [new_partial]} = Enum.split(parts, length(parts) - 1)

    {lines, remaining_partial} =
      if final?(opts) and new_partial != "" do
        {Enum.reverse([new_partial | Enum.reverse(complete_lines)]), ""}
      else
        {complete_lines, new_partial}
      end

    {Enum.map(lines, &decode_utf8_lenient/1), size, remaining_partial}
  end

  # coveralls-ignore-start (defensive file read error fallback)
  defp split_lines(_read_error, _size, file_offset, partial_line, _opts) do
    {[], file_offset, partial_line}
  end

  # coveralls-ignore-stop

  defp finalize_partial_line(partial_line, file_offset, opts) do
    if final?(opts) and partial_line != "" do
      {[decode_utf8_lenient(partial_line)], file_offset, ""}
    else
      {[], file_offset, partial_line}
    end
  end

  defp final?(opts), do: Keyword.get(opts, :final, false)
end
