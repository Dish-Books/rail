defmodule RailWeb.Mcp.Tools.CreateIssue do
  @moduledoc """
  Files a ticket in a project, or a sub-issue under one of its tickets, as you. It is assigned to you unless you name
  someone else, or no one with an empty assignee.
  """

  use Anubis.Server.Component, type: :tool

  import RailWeb.Utils.McpErrorResponse
  import RailWeb.Utils.ReadMcpIssue

  alias Anubis.Server.Response
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Users
  alias RailWeb.Mcp.IssueJSON

  @priorities %{"urgent" => :urgent, "high" => :high, "medium" => :medium, "low" => :low}

  schema do
    field :project, {:required, :string}, description: "A project's key or name, from list_projects."
    field :title, {:required, :string}
    field :description, :string, description: "Markdown."
    field :priority, {:enum, Map.keys(@priorities)}
    field :estimate, :integer, description: "Points."
    field :parent, :string, description: "The identifier of the ticket this is a sub-issue of."
    field :assignee, :string, description: "A GitHub login, or empty for no one. Left out, you."
  end

  @impl true
  def execute(params, %{assigns: %{current_scope: scope}} = frame) do
    # A field sent as null is left out, so a null assignee still means the person.
    params = Map.reject(params, fn {_field, value} -> is_nil(value) end)

    with {:ok, project} <- Projects.find_project(scope, params.project),
         {:ok, parent} <- find_parent(scope, project, params[:parent]),
         {:ok, owner_user_id, note} <- find_owner(scope, project, params) do
      attrs = %{
        title: params.title,
        description: params[:description] || "",
        priority: @priorities[params[:priority]],
        estimate: params[:estimate],
        owner_user_id: owner_user_id,
        parent: parent
      }

      with {:ok, issue} <- Issues.create_issue(scope, project, attrs),
           {:ok, assigns} <- read_mcp_issue(scope, issue.identifier) do
        {:reply, Response.json(Response.tool(), IssueJSON.show(Map.merge(assigns, note))), frame}
      else
        {:error, reason} -> {:reply, mcp_error_response(reason), frame}
      end
    else
      {:error, reason} -> {:reply, mcp_error_response(reason), frame}
    end
  end

  defp find_parent(_scope, %Project{}, nil), do: {:ok, nil}
  defp find_parent(_scope, %Project{tracker: :github}, _parent), do: {:error, :parent_on_github}

  defp find_parent(scope, %Project{id: project_id}, identifier) do
    case Issues.find_issue(scope, identifier) do
      {:ok, %Issue{project_id: ^project_id} = parent} -> {:ok, parent}
      _elsewhere -> {:error, {:invalid, :parent, "#{identifier} is not a ticket in this project"}}
    end
  end

  # Where the tracker cannot assign the person, such as Linear before they connect it, the ticket is filed unassigned.
  defp find_owner(scope, %Project{} = project, params) do
    assignable = Users.list_assignable_users(project_id: project.id, tracker: project.tracker)

    case params |> Map.get(:assignee, :me) |> then(&if(is_binary(&1), do: String.trim(&1), else: &1)) do
      :me ->
        if Enum.any?(assignable, &(&1.id == scope.user.id)),
          do: {:ok, scope.user.id, %{}},
          else:
            {:ok, nil, %{note: "Filed unassigned: #{Issue.tracker_label(project.tracker)} can't assign it to you yet."}}

      "" ->
        {:ok, nil, %{}}

      login ->
        case Enum.find(assignable, &(String.downcase(&1.login || "") == String.downcase(login))) do
          %{id: id} -> {:ok, id, %{}}
          nil -> {:error, {:invalid, :assignee, "#{login} can't be assigned a ticket in #{project.key}"}}
        end
    end
  end
end
