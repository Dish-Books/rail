defmodule Rail.Pipeline.Actions.SendDiffComments do
  @moduledoc """
  Sends the comments a person left on the diff and has not sent yet to the
  engineer, as one message, and marks them sent.

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

  Returns what `Rail.Pipeline.send_message/2` does, or `{:error, :nothing_to_send}`
  when none are unsent.
  """
  def send_diff_comments(%Scope{user: %{id: user_id}} = scope, %Run{task_id: task_id} = run) do
    mine = from comment in DiffComment, where: comment.task_id == ^task_id and comment.user_id == ^user_id

    # Claimed before sending, so a second tab's Send finds nothing left to send.
    # Committed rather than held in a transaction: the dispatch reads the run from
    # another process, which would not see an uncommitted message.
    {_claimed, comments} =
      Repo.update_all(from(comment in mine, where: comment.status == :unsent, select: comment),
        set: [status: :sent, updated_at: DateTime.utc_now()]
      )

    comments = Enum.sort_by(comments, &{&1.path, DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})

    with [_first | _rest] <- comments,
         {:ok, _delivery, _run} = sent <- Pipeline.send_message(scope, run, format(comments)) do
      {:ok, _learned} = Learnings.record_corrections(Repo.get!(Task, task_id), comments)
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

    Enum.join([heading | Enum.map(comments, &block/1)], "\n\n")
  end

  defp block(%DiffComment{} = comment) do
    "#{comment.path}, #{line_label(comment)}\n#{quote_code(comment)}\n#{comment.body}"
  end

  # A comment saved before blocks were kept has only its line to quote.
  defp quote_code(%DiffComment{context_text: context}) when is_binary(context) and context != "", do: context

  defp quote_code(%DiffComment{} = comment), do: "#{glyph(comment.line_kind)} #{String.trim_trailing(comment.line_text)}"

  defp line_label(%DiffComment{line_kind: :deleted, line: line}), do: "removed line #{line}"
  defp line_label(%DiffComment{line: line}), do: "line #{line}"

  defp glyph(:added), do: "+"
  defp glyph(:deleted), do: "-"
  defp glyph(:context), do: " "
end
