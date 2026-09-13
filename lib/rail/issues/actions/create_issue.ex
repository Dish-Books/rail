defmodule Rail.Issues.Actions.CreateIssue do
  @moduledoc """
  Opens a ticket in Linear and records it locally.

  Creating stays synchronous, unlike every later write. Linear is what names an
  issue — `identifier`, `branch_name`, the URL — and the pipeline uses those the
  moment the row exists: the branch a worktree is cut on and the scratch file a
  product run writes its ticket into are both named after them. An issue that had
  to wait for them would be an issue nothing could act on yet.

  A caller with only prose to hand can leave `:title` out: the first line of the
  description becomes it, trimmed to something a list can show.
  """

  import Rail.Issues.Utils.TokenResolver

  alias Rail.Issues.Clients.Linear
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @title_limit 90

  @doc """
  Creates the Linear ticket for `attrs` and inserts the issue it came back as.

  `attrs` carries `:description` and optionally `:title`, `:priority` and
  `:owner_user_id`. The ticket is opened as the workspace.
  """
  def create_issue(%Project{} = project, attrs) do
    with {:ok, token} <- workspace_token(project) do
      description = attrs[:description]

      linear_attrs = %{
        team_id: project.linear_team_id,
        title: title(attrs[:title], description),
        description: description,
        state_id: triage_state_id(project)
      }

      case Linear.create_issue(token, linear_attrs) do
        {:ok, linear_issue} -> insert(project, linear_issue, attrs)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp insert(%Project{} = project, linear_issue, attrs) do
    local_attrs = %{
      project_id: project.id,
      owner_user_id: attrs[:owner_user_id],
      external_id: linear_issue.id,
      identifier: linear_issue.identifier,
      title: linear_issue.title,
      description: linear_issue.description,
      priority: attrs[:priority] || linear_issue.priority || :medium,
      estimate: linear_issue.estimate,
      state: :triage,
      state_name: (linear_issue.state && linear_issue.state.name) || "Triage",
      branch_name: linear_issue.branch_name,
      url: linear_issue.url,
      linear_created_at: parse_datetime(linear_issue.created_at),
      linear_updated_at: parse_datetime(linear_issue.updated_at)
    }

    # The project is what the caller already handed us: carry it on the issue so
    # nothing downstream has to fetch it again.
    case %Issue{} |> Issue.changeset(local_attrs) |> Repo.insert() do
      {:ok, %Issue{} = issue} -> {:ok, %{issue | project: project}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # The first thing the human wrote is the title; the rest is the body. A long
  # first line is cut at a word boundary so the title still reads as a phrase.
  defp title(given, _description) when is_binary(given) and given != "", do: given

  defp title(_missing, description) when is_binary(description) do
    description
    |> String.split(~r/\r?\n/)
    |> Enum.find_value("", fn line ->
      trimmed = String.trim(line)
      if trimmed == "", do: nil, else: trimmed
    end)
    |> truncate()
  end

  defp title(_missing, _nothing), do: nil

  defp truncate(title) when byte_size(title) == 0, do: title

  defp truncate(title) do
    if String.length(title) <= @title_limit do
      title
    else
      cut(title, String.slice(title, 0, @title_limit))
    end
  end

  defp cut(title, head) do
    case Regex.scan(~r/\s/, head, return: :index) do
      [] ->
        head <> "…"

      matches ->
        title |> String.slice(0, matches |> List.last() |> hd() |> elem(0)) |> String.trim_trailing() |> Kernel.<>("…")
    end
  end

  defp triage_state_id(%Project{linear_state_ids: ids}) do
    ids["triage"] || ids[:triage]
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, datetime, _offset} -> datetime
      _unparseable -> nil
    end
  end
end
