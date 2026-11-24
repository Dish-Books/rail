defmodule RailWeb.Mcp.Tools.ListInitiatives do
  @moduledoc """
  Lists initiatives, each a project's group of tickets across cycles, with percent done (Done tickets out of those not
  Canceled) and the expected date. A ticket's initiative is set by name in create_issue and update_issue.
  """

  use Anubis.Server.Component, type: :tool, annotations: %{readOnlyHint: true}

  import RailWeb.Utils.McpErrorResponse

  alias Anubis.Server.Response
  alias Rail.Initiatives
  alias Rail.Projects
  alias RailWeb.Mcp.InitiativeJSON

  schema do
    field :project, :string,
      description: "A project's key or name, from list_projects. Left out, every project you can open."
  end

  @impl true
  def execute(params, %{assigns: %{current_scope: scope}} = frame) do
    case project_id(scope, params[:project]) do
      {:ok, project_id} ->
        initiatives = Initiatives.list_initiatives(scope, project_id: project_id)
        json = InitiativeJSON.index(%{initiatives: initiatives, today: Date.utc_today()})
        {:reply, Response.json(Response.tool(), json), frame}

      {:error, reason} ->
        {:reply, mcp_error_response(reason), frame}
    end
  end

  defp project_id(_scope, nil), do: {:ok, nil}

  defp project_id(scope, wanted) do
    with {:ok, project} <- Projects.find_project(scope, wanted), do: {:ok, project.id}
  end
end
