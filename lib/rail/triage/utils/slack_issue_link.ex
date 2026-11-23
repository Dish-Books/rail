defmodule Rail.Triage.Utils.SlackIssueLink do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue

  @doc """
  How an issue is linked in a Slack post: its identifier, linking to its page.
  """
  def slack_issue_link(%Issue{url: url, identifier: identifier}), do: "<#{url}|#{identifier}>"
end
