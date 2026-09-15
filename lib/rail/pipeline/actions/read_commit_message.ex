defmodule Rail.Pipeline.Actions.ReadCommitMessage do
  @moduledoc """
  Reads the commit message the engineer wrote into its task's scratch directory.

  Writing this file is how an engineer run says it is finished, the way the
  architect says so by writing a plan. It lives at
  `<scratch>/commits/<identifier>.md` and Rail deletes it once the commit it
  describes exists, so the file being there always means "there is work here
  nobody has committed yet".
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns the message the engineer wrote, or `nil` when there is none yet.

  A blank file is no message: the agent opened it but never wrote it. Requires
  `issue` to be preloaded.
  """
  def read_commit_message(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    case [scratch_path, "commits", "#{identifier}.md"] |> Path.join() |> File.read() do
      {:ok, content} -> if String.trim(content) == "", do: nil, else: String.trim(content)
      {:error, _unreadable} -> nil
    end
  end
end
