defmodule Rail.Issues.Actions.UploadAsset do
  @moduledoc false

  alias Rail.Issues.Tracker

  @doc """
  Stores a file where `target`'s tickets can link to it and returns its URL, or
  `{:error, :unsupported}` from a tracker that cannot hold files.
  """
  def upload_asset(target, filename, content_type, data_binary),
    do: Tracker.tracker(target).upload_asset(target, filename, content_type, data_binary)
end
