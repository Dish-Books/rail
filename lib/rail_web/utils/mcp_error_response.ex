defmodule RailWeb.Utils.McpErrorResponse do
  @moduledoc """
  Turns why a tool failed into a tool result with `isError` and one sentence, rather than a protocol error, so Claude
  reads why and can correct the call.
  """

  alias Anubis.Server.Response
  alias Rail.Issues.Schemas.Issue

  def mcp_error_response(reason), do: Response.error(Response.tool(), message(reason))

  defp message({:not_found, keys}) when is_list(keys) do
    case keys do
      [] -> "You can't open any project in Rail."
      keys -> "No project you can open has that key or name. Yours are: #{Enum.join(keys, ", ")}."
    end
  end

  defp message({:issue_not_found, identifier}),
    do: "No ticket #{identifier} in a project you can open. Use its identifier, such as RAIL-12."

  defp message({:edited_in_tracker, tracker, fields}) do
    label = Issue.tracker_label(tracker)

    "A #{label} ticket's #{join(fields)} #{if length(fields) == 1, do: "is", else: "are"} edited in #{label}, so " <>
      "nothing was changed. Only its status and assignee change here, and it takes comments."
  end

  defp message({:invalid, field, detail}), do: "#{field} #{detail}."

  defp message({:partly_saved, saved, failed, reason}),
    do: "Saved #{join(saved)}, but not #{join(failed)}: #{message(reason)}"

  defp message(%Ecto.Changeset{} = changeset) do
    errors =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {text, opts} ->
        Enum.reduce(opts, text, fn {key, value}, acc -> String.replace(acc, "%{#{key}}", to_string(value)) end)
      end)
      |> Enum.map_join("; ", fn {field, texts} -> "#{field} #{Enum.join(texts, ", ")}" end)

    "#{errors}."
  end

  defp message(:not_found), do: "That ticket is gone, or you can no longer open it."
  defp message(:split_child), do: "A sub-issue of a split task keeps its parent's assignee."
  defp message(:not_assignable), do: "That person can't be assigned this ticket."
  defp message(:unsupported), do: "That is edited in the ticket's own tracker."
  defp message({:already_blocks, identifiers}), do: "This ticket already blocks #{join(identifiers)}."
  defp message(:search_unavailable), do: "Ticket search is unavailable right now, so nothing was searched."

  defp message(:cycle_not_tracked),
    do: "Only a Rail-tracked project's tickets can be listed by cycle; name one with `project`."

  defp message(:parent_on_github),
    do: "GitHub keeps no parent, so a GitHub project's ticket can't be filed as a sub-issue."

  defp message(:blank_body), do: "The comment is empty, so nothing was posted."
  defp message(reason) when is_binary(reason), do: reason
  # A tracker's own failure, such as Linear being unreachable, in whatever shape it came.
  defp message(reason), do: "The ticket's tracker refused it: #{inspect(reason)}."

  defp join(fields), do: Enum.map_join(fields, ", ", &to_string/1)
end
