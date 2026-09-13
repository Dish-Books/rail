defmodule Rail.Tools.Utils.DecodeUtf8Lenient do
  @moduledoc false

  @doc """
  Decodes binary to UTF-8 leniently, replacing invalid or incomplete byte sequences with replacement characters.
  """
  def decode_utf8_lenient(binary) when is_binary(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      decoded when is_binary(decoded) ->
        decoded

      {:error, valid, rest} ->
        <<_bad::binary-size(1), tail::binary>> = rest
        valid <> "�" <> decode_utf8_lenient(tail)

      {:incomplete, valid, rest} ->
        valid <> String.duplicate("�", byte_size(rest))

      # coveralls-ignore-start (defensive unicode fallback)
      _other ->
        binary
        # coveralls-ignore-stop
    end
  end
end
