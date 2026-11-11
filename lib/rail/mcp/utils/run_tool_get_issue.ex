defmodule Rail.Mcp.Utils.RunToolGetIssue do
  @moduledoc """
  Opens one of the role's project's tickets by its identifier, with its comments, for an agent judging a likely match.
  A ticket Rail has not mirrored yet is brought in from the project's tracker, as triage brings in the ones it cites.
  """

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Roles.Schemas.Role

  @doc "Returns the ticket `arguments[\"identifier\"]` names in `role`'s project as markdown, or a sentence saying why not."
  def run_tool_get_issue(%Role{} = role, %{"identifier" => identifier}, _opts) when is_binary(identifier) do
    if String.trim(identifier) == "",
      do: run_tool_get_issue(role, %{}, []),
      else: open(role, String.trim(identifier))
  end

  def run_tool_get_issue(%Role{}, _arguments, _opts) do
    {:ok, "get_issue needs an `identifier`, such as one `search_issues` listed. Nothing was opened."}
  end

  defp open(%Role{project_id: project_id}, identifier) do
    with {:ok, project} <- Projects.get_project(project_id),
         {:ok, %Issue{id: id}} <- Issues.import_issue(project, identifier),
         {:ok, issue} <-
           Issues.get_issue(id, preload: [comments: from(c in Comment, order_by: [asc: c.inserted_at, asc: c.id])]) do
      {:ok, render(issue)}
    else
      {:error, :not_found} ->
        {:ok, "No ticket #{identifier} in this project."}

      {:error, _tracker_failed} ->
        {:ok, "Rail could not fetch #{identifier} from the project's tracker. Try again later."}
    end
  end

  defp render(%Issue{} = issue) do
    comments =
      case issue.comments do
        [] ->
          "No comments."

        comments ->
          Enum.map_join(comments, "\n\n", fn %Comment{} = comment ->
            "### #{comment.author_name || "Unknown"} · #{Calendar.strftime(comment.inserted_at, "%Y-%m-%d %H:%M UTC")}\n\n" <>
              comment.body
          end)
      end

    """
    # `#{issue.identifier}` #{issue.title}

    - Status: #{Issue.calculate_status_name(issue)}
    - Priority: #{Issue.priority_label(issue.priority) || "None"}
    - Estimate: #{issue.estimate || "None"}
    - URL: #{issue.url || "None"}

    ## Description

    #{blank(issue.description, "No description.")}

    ## Comments

    #{comments}
    """
  end

  defp blank(text, empty) when is_binary(text), do: if(String.trim(text) == "", do: empty, else: text)
  defp blank(nil, empty), do: empty
end
