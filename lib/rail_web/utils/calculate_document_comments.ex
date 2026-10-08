defmodule RailWeb.Utils.CalculateDocumentComments do
  @moduledoc """
  Where a reader's unsent comments on the ticket or the plan sit: under the line they were written on while one still
  reads the same, or lifted to the top of the document once none does, as a diff comment is lifted off its line.
  """

  @doc """
  Places `numbered_comments`, one document's comments with their tray numbers in round order, on its `lines`. Returns
  `placed`, each line's comments by its key in round order, and `lifted`, those no line reads as any more.

  A comment stays on the copy of its line it was written on, and falls back to the first copy once that one is gone.
  """
  def calculate_document_comments(lines, numbered_comments) do
    copies = Enum.group_by(lines, &{&1.kind, &1.text})

    {placed, lifted} =
      Enum.reduce(numbered_comments, {%{}, []}, fn {comment, _number} = numbered, {placed, lifted} ->
        same = Map.get(copies, {comment.element_kind, comment.element_text}, [])

        case Enum.find(same, &(&1.occurrence == comment.element_occurrence)) || List.first(same) do
          %{key: key} -> {Map.update(placed, key, [numbered], &[numbered | &1]), lifted}
          nil -> {placed, [numbered | lifted]}
        end
      end)

    %{placed: Map.new(placed, fn {key, comments} -> {key, Enum.reverse(comments)} end), lifted: Enum.reverse(lifted)}
  end
end
