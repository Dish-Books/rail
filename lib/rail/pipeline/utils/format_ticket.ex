defmodule Rail.Pipeline.Utils.FormatTicket do
  @moduledoc false
  alias Rail.Issues.Schemas.Issue

  @doc """
  Writes an issue out as the ticket markdown `parse_ticket/1` reads back.

  A field the issue has nothing for is left out rather than written empty, so a
  round trip through the scratch file does not invent a priority or an estimate.
  """
  def format_ticket(%Issue{} = issue) do
    fields =
      [
        {"title", String.trim(issue.title || "")},
        {"priority", issue.priority && Atom.to_string(issue.priority)},
        {"estimate", issue.estimate && Integer.to_string(issue.estimate)}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Enum.map_join("\n", fn {key, value} -> "#{key}: #{value}" end)

    description = if is_binary(issue.description), do: String.trim(issue.description), else: ""

    String.trim_trailing("---\n#{fields}\n---\n\n#{description}") <> "\n"
  end
end
