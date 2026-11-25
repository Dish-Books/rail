defmodule RailWeb.Utils.McpErrorResponse do
  @moduledoc """
  Turns why a tool failed into a tool result with `isError` and one sentence, rather than a protocol error, so Claude
  reads why and can correct the call.
  """

  alias Anubis.Server.Response
  alias Rail.Pipeline.Schemas.Task

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

  defp message({:no_task, identifier}),
    do: "#{identifier} has no task in Rail: it was never started, or its task was cleaned up after merging."

  defp message({:finding_not_found, identifier, key}),
    do: "#{identifier} has no finding #{key}. list_findings gives each finding's key."

  defp message(:round_changed_during_read),
    do:
      "A new review round opened while Rail read the findings, so it returned nothing and saved nothing. " <>
        "Read them again with list_findings."

  defp message(:ruled_round_changed),
    do: "Your ruling is saved, but a new review round opened as Rail read it back. Read it again with list_findings."

  defp message({:ruled_unread, reason}), do: "Your ruling is saved, but Rail could not read it back: #{message(reason)}"

  defp message(:round_changed),
    do:
      "A new review round opened since you read that finding, so nothing was saved. " <>
        "Read it again with list_findings, then rule."

  defp message(:finding_changed),
    do: "That finding changed since you read it, so nothing was saved. Read it again with list_findings, then rule."

  defp message({:invalid_stage, stage}),
    do: "This task is at #{Task.stage_label(stage)}, not Review, so its findings can't be ruled on."

  defp message(:stage_running), do: "A run is working on this task. Rule once it stops."
  defp message(:review_finished), do: "The review is finished, so its rulings are settled."
  defp message(:issue_filed), do: "That finding is filed as a new issue, so its ruling can no longer change."
  defp message(:finding_fixed), do: "That finding is fixed, so its ruling can no longer change."
  defp message(:suppressed), do: "A rule already leaves that finding alone, so the only ruling it takes is fix."
  defp message(reason) when is_binary(reason), do: reason
  # A failure with no sentence of its own, in whatever shape it came.
  defp message(reason), do: "Rail could not do that: #{inspect(reason)}."

  defp join(fields), do: Enum.map_join(fields, ", ", &to_string/1)
end
