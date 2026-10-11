defmodule Rail.Pipeline.Actions.SendDiffComments do
  @moduledoc """
  Sends the comments a person left on the diff and has not sent yet to the
  engineer, as one message, and marks them sent. From Review on they go out with the
  tray's Send instead, so a stale page cannot send them to the lead on their own.

  Each quotes the code around its line as written, since line numbers move as the
  engineer edits. What was sent is learned from.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastDiffComments

  alias Rail.Learnings
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Sends the scope user's unsent comments on `run`'s task to `run`.

  Returns what `Rail.Pipeline.send_message/2` does, `{:error, :nothing_to_send}`
  when none are unsent, or `{:error, {:invalid_stage, stage}}` at Review, Finalize or merged.
  """
  def send_diff_comments(%Scope{} = scope, %Run{task_id: task_id} = run) do
    case Repo.get!(Task, task_id) do
      %Task{stage: stage} when stage in [:review, :finalize, :merged] -> {:error, {:invalid_stage, stage}}
      %Task{} = task -> send_comments(scope, run, task)
    end
  end

  defp send_comments(%Scope{user: %{id: user_id}} = scope, %Run{task_id: task_id} = run, %Task{} = task) do
    mine = from comment in DiffComment, where: comment.task_id == ^task_id and comment.user_id == ^user_id

    # Claimed before sending, so a second tab's Send finds nothing left to send.
    # Committed rather than held in a transaction: the dispatch reads the run from
    # another process, which would not see an uncommitted message.
    {_claimed, comments} =
      Repo.update_all(from(comment in mine, where: comment.status == :unsent, select: comment),
        set: [status: :sent, updated_at: DateTime.utc_now()]
      )

    comments = DiffComment.calculate_order(comments)

    with [_first | _rest] <- comments,
         {:ok, _delivery, _run} = sent <- Pipeline.send_message(scope, run, format(comments)) do
      {:ok, _learned} = Learnings.record_corrections(task, comments)
      broadcast_diff_comments(task_id, :everyone)
      sent
    else
      [] ->
        {:error, :nothing_to_send}

      {:error, reason} ->
        ids = Enum.map(comments, & &1.id)

        Repo.update_all(from(comment in mine, where: comment.id in ^ids and comment.status == :sent),
          set: [status: :unsent, updated_at: DateTime.utc_now()]
        )

        {:error, reason}
    end
  end

  defp format(comments) do
    heading = if length(comments) == 1, do: "1 comment on the diff", else: "#{length(comments)} comments on the diff"

    Enum.join([heading | Enum.map(comments, &DiffComment.calculate_block/1)], "\n\n")
  end
end
