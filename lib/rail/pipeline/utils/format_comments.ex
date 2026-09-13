defmodule Rail.Pipeline.Utils.FormatComments do
  @moduledoc false
  alias Rail.Issues.Schemas.Comment

  @doc """
  Writes an issue's comments out for an agent to read, oldest first, each reply
  nested inside the comment it answers.

  Takes the issue's comments with `:replies` loaded; replies in the flat list are
  skipped, since they are written under their parent.
  """
  def format_comments(comments) when is_list(comments) do
    case comments |> Enum.filter(&is_nil(&1.parent_id)) |> oldest_first() do
      [] -> "The issue has no comments."
      top_level -> Enum.map_join(top_level, "\n\n", &tag("comment", &1, oldest_first(&1.replies)))
    end
  end

  defp tag(name, %Comment{} = comment, replies) do
    lines = [
      ~s(<#{name} author="#{author(comment)}" at="#{DateTime.to_iso8601(comment.inserted_at)}">),
      String.trim(comment.body || "") | Enum.map(replies, &tag("reply", &1, []))
    ]

    Enum.join(lines, "\n") <> "\n</#{name}>"
  end

  defp author(%Comment{author_name: name}) when is_binary(name) and name != "", do: name
  defp author(%Comment{}), do: "Unknown"

  defp oldest_first(comments), do: Enum.sort_by(comments, & &1.inserted_at, DateTime)
end
