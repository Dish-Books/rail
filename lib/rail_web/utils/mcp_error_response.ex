defmodule RailWeb.Utils.McpErrorResponse do
  @moduledoc """
  Turns why a tool failed into a tool result with `isError` and one sentence, rather than a protocol error, so Claude
  reads why and can correct the call.
  """

  alias Anubis.Server.Response

  def mcp_error_response(reason), do: Response.error(Response.tool(), message(reason))

  defp message({:not_found, keys}) when is_list(keys) do
    case keys do
      [] -> "You can't open any project in Rail."
      keys -> "No project you can open has that key or name. Yours are: #{Enum.join(keys, ", ")}."
    end
  end

  defp message({:issue_not_found, identifier}),
    do: "No ticket #{identifier} in a project you can open. Use its identifier, such as RAIL-12."

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
  defp message({:already_blocks, identifiers}), do: "This ticket already blocks #{join(identifiers)}."
  defp message(:search_unavailable), do: "Ticket search is unavailable right now, so nothing was searched."

  defp message(:cycle_not_tracked), do: "Tickets are listed by cycle within one project; name it with `project`."

  defp message(:blank_body), do: "The comment is empty, so nothing was posted."
  defp message(reason) when is_binary(reason), do: reason
  # A failure with no sentence of its own, in whatever shape it came.
  defp message(reason), do: "Rail could not do that: #{inspect(reason)}."

  defp join(fields), do: Enum.map_join(fields, ", ", &to_string/1)
end
