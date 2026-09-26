defmodule Rail.Triage.Utils.SlackIssueLink do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue

  @doc """
  How an issue is linked in a Slack post: its identifier, as a link when Linear gave it a URL.
  """
  def slack_issue_link(%Issue{url: url, identifier: identifier}) when is_binary(url), do: "<#{url}|#{identifier}>"
  def slack_issue_link(%Issue{identifier: identifier}), do: identifier
end
