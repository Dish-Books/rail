defmodule Rail.Issues.Actions.UploadAsset do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker

  @doc """
  Stores a file `issue` (its project preloaded) can link to and returns its URL.
  """
  def upload_asset(%Issue{} = issue, filename, content_type, data_binary),
    do: Tracker.upload_asset(issue, filename, content_type, data_binary)
end
