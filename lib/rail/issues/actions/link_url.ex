defmodule Rail.Issues.Actions.LinkUrl do
  @moduledoc """
  Queues a link from an issue's ticket to a URL, so a slow or failing tracker retries in the
  background instead of failing whatever asked.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.LinkTrackerUrl

  @doc """
  Enqueues `Rail.Issues.Workers.LinkTrackerUrl` to link `url` to `issue`'s ticket under `title`.
  """
  def link_url(%Issue{} = issue, url, title) when is_binary(url) and is_binary(title) do
    %{issue_id: issue.id, url: url, title: title}
    |> LinkTrackerUrl.new()
    |> Oban.insert()
  end
end
