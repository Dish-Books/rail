defmodule RailWeb.Utils.IssueRelative do
  @moduledoc """
  Whether a changed issue touches the one a page shows: the issue itself, its parent, a sub-issue, a blocker or an
  issue it blocks, or one that now names it as parent. `"issues"` carries every project's changes, so this decides
  whether the page reads it again.
  """
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue

  # Only the last needs the changed issue looked up; the rest are on the page already.
  def issue_relative?(%Issue{} = issue, blockers, changed_issue_id) when is_binary(changed_issue_id) do
    related = for %{issue: %Issue{id: id}} <- (blockers && blockers.blocked_by ++ blockers.blocks) || [], do: id
    parent = Issue.calculate_parent(issue)
    loaded = [issue.id, parent && parent.id] ++ Enum.map(Issue.calculate_children(issue), & &1.id) ++ related

    changed_issue_id in loaded or
      match?(
        {:ok, %Issue{parent_external_id: external_id}} when external_id == issue.external_id,
        Issues.get_issue(changed_issue_id, preload: [])
      )
  end
end
