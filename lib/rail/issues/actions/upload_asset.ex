defmodule Rail.Issues.Actions.UploadAsset do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker

  @doc """
  Stores a file `issue` (its project preloaded) can link to and returns its URL, or
  `{:error, :unsupported}` from a tracker that cannot hold files.
  """
  def upload_asset(%Issue{} = issue, filename, content_type, data_binary),
    do: Tracker.tracker(issue).upload_asset(issue, filename, content_type, data_binary)
end
