defmodule Rail.Git.Utils.ImageType do
  @moduledoc false

  # Pictures a browser draws from their bytes alone. An SVG is text, so its diff is
  # read as lines, and served as a page it could run script.
  @types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".avif" => "image/avif",
    ".bmp" => "image/bmp",
    ".ico" => "image/x-icon"
  }

  @doc """
  The type `path` is served as when it is a picture, by its extension, or `nil`.
  """
  def image_type(path) when is_binary(path), do: Map.get(@types, path |> Path.extname() |> String.downcase())
end
