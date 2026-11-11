defmodule Rail.Issues.Actions.UploadFile do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Scope

  # The type comes from the name, never from the browser, so no upload is served as anything but an image or a PDF.
  @types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".pdf" => "application/pdf"
  }

  @doc """
  Stores an image or a PDF a person put into a Rail-tracked issue's description and returns its URL. Only a PNG, JPEG,
  GIF, WebP or PDF name is taken.
  """
  def upload_file(%Scope{} = scope, %Issue{} = issue, filename, data) when is_binary(filename) and is_binary(data) do
    content_type = @types[filename |> Path.extname() |> String.downcase()]

    cond do
      not Scope.can_access_project?(scope, issue.project_id) -> {:error, :not_found}
      issue.tracker != :local -> {:error, :unsupported}
      is_nil(content_type) -> {:error, :not_accepted}
      true -> Tracker.tracker(issue).upload_asset(issue, filename, content_type, data)
    end
  end
end
