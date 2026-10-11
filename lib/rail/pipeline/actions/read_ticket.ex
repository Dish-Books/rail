defmodule Rail.Pipeline.Actions.ReadTicket do
  @moduledoc """
  Reads the ticket a product run saved into its task's scratch directory.

  The ticket lives in scratch until a human approves it, at
  `<scratch>/tickets/<identifier>.md`, which `save_ticket` writes. A child of a split never runs Plan:
  approval wrote its ticket straight onto its own issue.
  """

  import Rail.Pipeline.Utils.ParseTicket

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Returns the parsed ticket `task`'s product run saved, with `:saved_at` saying
  when, or `nil` when there is none yet. A child of a split reads its own issue, saved when the child was made.

  A blank file is no ticket. Requires `issue` to be preloaded.
  """
  def read_ticket(%Task{parent_task_id: parent_task_id, issue: %Issue{} = issue} = task) when is_binary(parent_task_id) do
    %{
      title: issue.title,
      description: issue.description || "",
      priority: issue.priority,
      estimate: issue.estimate,
      saved_at: task.inserted_at
    }
  end

  def read_ticket(%Task{scratch_path: scratch_path, issue: %Issue{identifier: identifier}}) do
    path = Path.join([scratch_path, "tickets", "#{identifier}.md"])

    with {:ok, content} <- File.read(path),
         false <- String.trim(content) == "",
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix) do
      content |> parse_ticket() |> Map.put(:saved_at, DateTime.from_unix!(mtime))
    else
      _no_ticket -> nil
    end
  end
end
