defmodule RailWeb.Mcp.Tools.ListIssues do
  @moduledoc """
  Lists tickets most recently updated first, in one project or every project you can open, with how many match in all.
  Finished tickets are left out unless asked for.
  """

  use Anubis.Server.Component, type: :tool, annotations: %{readOnlyHint: true}

  import RailWeb.Utils.McpErrorResponse

  alias Anubis.Server.Response
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope
  alias Rail.Users
  alias RailWeb.Mcp.IssueJSON

  @states %{
    "triage" => :triage,
    "backlog" => :backlog,
    "todo" => :todo,
    "in_progress" => :in_progress,
    "in_review" => :in_review,
    "done" => :done,
    "canceled" => :canceled
  }

  schema do
    field :project, :string,
      description: "A project's key or name, from list_projects. Left out, every project you can open."

    field :state, {:enum, Map.keys(@states)}, description: "Only tickets in this state."
    field :assignee, :string, description: "`me`, or a GitHub login."
    field :cycle, :string, description: "`current`, `next` or a cycle's number, in a Rail-tracked project."
    field :query, :string, description: "Words in the title or identifier."
    field :finished, :boolean, default: false, description: "Include done and canceled tickets."
    field :limit, :integer, default: 50, description: "How many to return."
    field :offset, :integer, default: 0, description: "How many to skip, for the next page."
  end

  @impl true
  def execute(params, %{assigns: %{current_scope: scope}} = frame) do
    with {:ok, project} <- find_project(scope, params[:project]),
         {:ok, cycle_id} <- find_cycle(project, params[:cycle]),
         {:ok, owner_user_id} <- find_owner(scope, params[:assignee]) do
      state = @states[params[:state]]

      %{issues: issues, total: total} =
        Issues.list_issues(
          # Left out, only the projects the person can open: every project only for an admin.
          project_id: if(project, do: project.id, else: Scope.project_ids(scope)),
          cycle_id: cycle_id,
          owner_user_id: owner_user_id,
          state: state,
          search: params[:query],
          show_finished: params.finished or Issue.finished_state?(state),
          limit: max(params.limit, 1),
          offset: max(params.offset, 0),
          preload: [:owner_user]
        )

      {:reply, Response.json(Response.tool(), IssueJSON.index(%{issues: issues, total: total})), frame}
    else
      {:error, reason} -> {:reply, mcp_error_response(reason), frame}
    end
  end

  defp find_project(_scope, nil), do: {:ok, nil}
  defp find_project(scope, key_or_name), do: Projects.find_project(scope, key_or_name)

  defp find_cycle(_project, nil), do: {:ok, nil}

  defp find_cycle(%Project{tracker: :local} = project, wanted) do
    {:ok, %{cycles: cycles}} = Issues.get_cycles(project)
    current_index = Enum.find_index(cycles, & &1.current)

    found =
      case {String.downcase(String.trim(wanted)), Integer.parse(String.trim(wanted))} do
        {"current", _number} -> current_index && Enum.at(cycles, current_index)
        {"next", _number} -> current_index && Enum.at(cycles, current_index + 1)
        {_named, {number, ""}} -> Enum.find(cycles, &(&1.number == number))
        _unknown -> nil
      end

    case found do
      %{id: id} -> {:ok, id}
      nil -> {:error, {:invalid, :cycle, "is not current, next or a cycle number of #{project.key}"}}
    end
  end

  defp find_cycle(_project, _cycle), do: {:error, :cycle_not_tracked}

  defp find_owner(_scope, nil), do: {:ok, nil}

  defp find_owner(scope, login) do
    case {String.trim(login), Users.list_users_by_logins([String.trim(login)])} do
      {"me", _users} -> {:ok, scope.user.id}
      {_login, [user | _rest]} -> {:ok, user.id}
      {login, []} -> {:error, {:invalid, :assignee, "#{login} is no one in Rail"}}
    end
  end
end
