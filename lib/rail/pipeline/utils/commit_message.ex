defmodule Rail.Pipeline.Utils.CommitMessage do
  @moduledoc """
  The message a commit Rail makes carries.

  The engineer writes the subject and body; Rail adds the trailers that say
  which ticket this was and that Rail made the commit. A commit reached without
  a written message is one the human asked for from the diff pane, so it gets a
  subject saying exactly that rather than a blank one.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Builds the full commit message for `task` from what the engineer wrote.
  """
  def commit_message(%Task{issue: %Issue{} = issue}, written) do
    body = if is_binary(written) and String.trim(written) != "", do: String.trim(written), else: fallback(issue)
    config = Application.get_env(:rail, :git, [])
    bot_name = Keyword.get(config, :bot_name, "Rail")
    bot_email = Keyword.get(config, :bot_email, "rail[bot]@railai.dev")

    String.trim("""
    #{body}

    Ticket: #{issue.identifier}#{url(issue)}
    Co-Authored-By: #{bot_name} <#{bot_email}>
    """)
  end

  defp fallback(%Issue{identifier: identifier}), do: "#{identifier}: follow-up changes"

  defp url(%Issue{url: url}) when is_binary(url) and url != "", do: " #{url}"
  defp url(%Issue{}), do: ""
end
