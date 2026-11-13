defmodule RailWeb.Mcp.IssueJSON do
  @moduledoc false

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Users.Schemas.User

  # A list line leaves out the description, comments and relations; get_issue reads them.
  def index(%{issues: issues} = assigns) do
    Map.merge(%{issues: Enum.map(issues, &line/1)}, Map.take(assigns, [:total]))
  end

  @doc """
  The ticket in full: its project, owner, parent, sub-issues and comments with their authors must be loaded. A
  Rail-tracked ticket carries the `cycle` and `blockers` it was read with.
  """
  def show(%{issue: %Issue{} = issue} = assigns) do
    full =
      issue
      |> line()
      |> Map.merge(%{
        description: issue.description || "",
        url: issue.url,
        parent: issue |> Issue.calculate_parent() |> related(),
        sub_issues: issue |> Issue.calculate_children() |> Enum.map(&related/1),
        comments:
          issue.comments
          |> Enum.filter(&is_nil(&1.parent_id))
          |> sort()
          |> Enum.map(&Map.put(comment(&1), :replies, &1.replies |> sort() |> Enum.map(fn reply -> comment(reply) end)))
      })
      |> Map.merge(kept(issue, assigns))

    %{issue: Map.merge(full, Map.take(assigns, [:note]))}
  end

  defp kept(%Issue{tracker: :local}, assigns) do
    %{
      cycle: cycle(assigns[:cycle]),
      blocked_by: Enum.map(assigns[:blockers][:blocked_by] || [], &related(&1.issue)),
      blocks: Enum.map(assigns[:blockers][:blocks] || [], &related(&1.issue))
    }
  end

  defp kept(%Issue{tracker: tracker}, _assigns) do
    label = Issue.tracker_label(tracker)
    %{cycle_and_blockers: "kept in #{label}: open the ticket there to see them"}
  end

  defp line(%Issue{} = issue) do
    put_assignee(
      %{
        identifier: issue.identifier,
        title: issue.title,
        status: Issue.calculate_status_name(issue),
        priority: issue.priority,
        estimate: issue.estimate
      },
      issue.owner_user
    )
  end

  # A search reads tickets without their owners, so its lines name none.
  defp put_assignee(data, %User{} = user), do: Map.put(data, :assignee, user.login)
  defp put_assignee(data, nil), do: Map.put(data, :assignee, nil)
  defp put_assignee(data, %Ecto.Association.NotLoaded{}), do: data

  defp related(nil), do: nil

  defp related(%Issue{} = issue),
    do: %{identifier: issue.identifier, title: issue.title, status: Issue.calculate_status_name(issue)}

  defp cycle(nil), do: nil
  defp cycle(cycle), do: %{number: cycle.number, starts_on: cycle.starts_on, ends_on: cycle.ends_on}

  defp comment(%Comment{} = comment), do: %{author: author(comment), body: comment.body, created_at: comment.inserted_at}

  defp author(%Comment{author_user: %User{login: login}}), do: login
  defp author(%Comment{author_name: name}), do: name

  defp sort(comments), do: Enum.sort_by(comments, &{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
end
