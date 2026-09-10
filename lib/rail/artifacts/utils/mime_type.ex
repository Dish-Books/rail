defmodule Rail.Artifacts.Utils.MimeType do
  @moduledoc false

  @doc """
  Infers the MIME content-type from a filename or URL.
  """
  def mime_type(filename_or_url) when is_binary(filename_or_url) do
    ext =
      filename_or_url
      |> URI.parse()
      |> Map.get(:path, "")
      |> Path.extname()
      |> String.downcase()

    case ext do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      _other -> "application/octet-stream"
    end
  end

  def mime_type(_value), do: "application/octet-stream"
end
