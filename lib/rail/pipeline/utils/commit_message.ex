defmodule Rail.Pipeline.Utils.CommitMessage do
  @moduledoc """
  The message a commit Rail makes carries.

  The engineer writes the subject and body; Rail adds the trailers that say
  which ticket this was and that Rail made the commit, and for a Review commit
  which step, a fix round or a merge follow-up, which the branch history labels it by. A commit reached without
  a message is one the human or a merge asked for, so it gets a subject saying
  exactly that rather than a blank one.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Builds the full commit message for `task` from what the engineer wrote, naming `step`, such as
  "Fix round 2" or "Merge follow-up", when one is given.
  """
  def commit_message(%Task{issue: %Issue{} = issue}, written, step \\ nil) do
    body = if is_binary(written) and String.trim(written) != "", do: String.trim(written), else: fallback(issue)
    config = Application.get_env(:rail, :git, [])
    bot_name = Keyword.get(config, :bot_name, "Rail")
    bot_email = Keyword.get(config, :bot_email, "rail[bot]@railai.dev")

    String.trim("""
    #{body}

    Ticket: #{issue.identifier}#{url(issue)}#{step(step)}
    Co-Authored-By: #{bot_name} <#{bot_email}>
    """)
  end

  defp step(nil), do: ""
  defp step(step) when is_binary(step), do: "\nRail-Step: #{step}"

  defp fallback(%Issue{identifier: identifier}), do: "#{identifier}: follow-up changes"

  defp url(%Issue{url: url}) when is_binary(url) and url != "", do: " #{url}"
  defp url(%Issue{}), do: ""
end
