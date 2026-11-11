defmodule Rail.Issues.Actions.UploadImage do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Scope

  # The type comes from the name, never from the browser, so no upload is served as anything but an image.
  @types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

  @doc """
  Stores an image a person put into a Rail-tracked issue's description and returns its URL. Only a PNG, JPEG, GIF or
  WebP name is taken.
  """
  def upload_image(%Scope{} = scope, %Issue{} = issue, filename, data) when is_binary(filename) and is_binary(data) do
    content_type = @types[filename |> Path.extname() |> String.downcase()]

    cond do
      not Scope.can_access_project?(scope, issue.project_id) -> {:error, :not_found}
      issue.tracker != :local -> {:error, :unsupported}
      is_nil(content_type) -> {:error, :not_an_image}
      true -> Tracker.tracker(issue).upload_asset(issue, filename, content_type, data)
    end
  end
end
