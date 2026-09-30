defmodule Rail.Pipeline.Actions.SendDiffComments do
  @moduledoc """
  Sends every comment a person left on the diff to the engineer, as one message.

  Each quotes its line as it read when it was written, since line numbers move
  as the engineer edits. Once sent, the conversation is their only record.
  """

  import Ecto.Query

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Sends the scope user's comments on `run`'s task to `run`.

  Returns what `Rail.Pipeline.send_message/2` does, or `{:error, :nothing_to_send}`
  when there are no comments.
  """
  def send_diff_comments(%Scope{user: %{id: user_id}}, %Run{task_id: task_id} = run) do
    mine = from comment in DiffComment, where: comment.task_id == ^task_id and comment.user_id == ^user_id

    with [_first | _rest] = comments <- Repo.all(from comment in mine, order_by: [:path, :inserted_at, :id]),
         {:ok, _delivery, _run} = sent <- Pipeline.send_message(run, format(comments)) do
      # Sent before deleting and outside a transaction: the dispatch reads the run
      # from another process, which would not see an uncommitted message.
      ids = Enum.map(comments, & &1.id)
      Repo.delete_all(from comment in mine, where: comment.id in ^ids)
      sent
    else
      [] -> {:error, :nothing_to_send}
      {:error, reason} -> {:error, reason}
    end
  end

  defp format(comments) do
    heading = if length(comments) == 1, do: "1 comment on the diff", else: "#{length(comments)} comments on the diff"

    Enum.map_join([heading | Enum.map(comments, &block/1)], "\n\n", & &1)
  end

  defp block(%DiffComment{} = comment) do
    "#{comment.path}, #{where(comment)}\n#{glyph(comment.line_kind)} #{String.trim(comment.line_text)}\n#{comment.body}"
  end

  defp where(%DiffComment{line_kind: :deleted, line: line}), do: "removed line #{line}"
  defp where(%DiffComment{line: line}), do: "line #{line}"

  defp glyph(:added), do: "+"
  defp glyph(:deleted), do: "-"
  defp glyph(:context), do: " "
end
