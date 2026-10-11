defmodule Rail.Issues.Actions.GetAsset do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker

  @doc """
  Fetches a file the tracker holds for `issue`, as the credentials that can read it.
  """
  def get_asset(%Issue{} = issue, path) when is_binary(path), do: Tracker.tracker(issue).get_asset(issue, path)
end
