defmodule Rail.Triage.Actions.ReadTriage do
  @moduledoc """
  Reads the result a triage pass wrote into its thread's scratch directory.

  What comes out of it is the agent's word, not Rail's, so an item missing its
  key or kind, or carrying a verdict that does not fit its kind, is no item
  rather than a crash.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Thread

  @key ~r/\A[a-z0-9][a-z0-9-]*\z/
  @changes ["raised", "widened", "narrowed", "added"]

  @doc """
  Returns `%{title:, messages:, items:}`, or `nil` for a file that is missing or
  not the shape agreed.
  """
  def read_triage(%Thread{} = thread) do
    path = Path.join(Thread.scratch_path(thread), "result.json")

    with {:ok, content} <- File.read(path),
         {:ok, %{"items" => items} = result} when is_list(items) <- Jason.decode(content) do
      %{
        title: text(result["title"]),
        messages: result |> Map.get("messages") |> List.wrap() |> Enum.flat_map(&message/1),
        items: Enum.flat_map(items, &item/1)
      }
    else
      _unreadable -> nil
    end
  end

  defp message(%{"ts" => ts} = message) when is_binary(ts) do
    [
      %{
        ts: ts,
        needs_response: message["needs_response"] != false,
        reason: text(message["reason"]),
        item_links:
          for %{"key" => key} = link <- List.wrap(message["items"]), is_binary(key) do
            %{item_key: key, change: enum(link["change"], @changes) || "raised", passage: text(link["passage"])}
          end
      }
    ]
  end

  defp message(_malformed), do: []

  defp item(%{"key" => key, "title" => title} = item) when is_binary(key) and is_binary(title) do
    kind = enum(item["kind"], Enum.map(Item.kinds(), &Atom.to_string/1))

    verdict =
      kind && enum(item["verdict"], kind |> String.to_existing_atom() |> Item.verdicts() |> Enum.map(&to_string/1))

    if Regex.match?(@key, key) and is_binary(verdict) and String.trim(title) != "" do
      issue = if is_map(item["issue"]), do: item["issue"], else: %{}

      [
        %{
          key: key,
          kind: kind,
          title: String.trim(title),
          verdict: verdict,
          summary: text(item["summary"]),
          evidence: for(%{} = evidence <- List.wrap(item["evidence"]), do: evidence(evidence)),
          assumptions: item["assumptions"] |> List.wrap() |> Enum.flat_map(&assumption/1),
          existing_issue: text(item["existing_issue"]),
          issue_note: text(item["issue_note"]),
          issue_title: text(issue["title"]),
          issue_description: text(issue["description"]),
          issue_priority: enum(issue["priority"], Enum.map(Issue.priorities(), &Atom.to_string/1)),
          reply_text: text(item["reply"])
        }
      ]
    else
      []
    end
  end

  defp item(_malformed), do: []

  defp evidence(evidence) do
    %{
      file: text(evidence["file"]),
      lines: text(to_string(evidence["lines"] || "")),
      excerpt: text(evidence["excerpt"]),
      holds: evidence["holds"] != false
    }
  end

  defp assumption(%{"text" => text} = assumption) when is_binary(text),
    do: [%{text: String.trim(text), corrected: assumption["corrected"] == true}]

  defp assumption(text) when is_binary(text), do: [%{text: String.trim(text), corrected: false}]
  defp assumption(_malformed), do: []

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_missing), do: nil

  defp enum(value, allowed) when is_binary(value), do: Enum.find(allowed, &(&1 == String.trim(value)))
  defp enum(_missing, _allowed), do: nil
end
