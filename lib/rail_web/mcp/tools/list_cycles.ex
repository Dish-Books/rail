defmodule RailWeb.Mcp.Tools.ListCycles do
  @moduledoc """
  Lists a project's cycles that have not ended, oldest first, and names the current one: the cycle that is
  running, or the next to start when none is. Any of them can be a ticket's cycle in create_issue and update_issue.
  """

  use Anubis.Server.Component, type: :tool, annotations: %{readOnlyHint: true}

  import RailWeb.Utils.McpErrorResponse

  alias Anubis.Server.Response
  alias Rail.Issues
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias RailWeb.Mcp.CycleJSON

  schema do
    field :project, {:required, :string}, description: "A project's key or name, from list_projects."
    field :ended, :boolean, default: false, description: "Include cycles that have ended."
  end

  @impl true
  def execute(params, %{assigns: %{current_scope: scope}} = frame) do
    with {:ok, project} <- Projects.find_project(scope, params.project),
         {:ok, cycles} <- read_cycles(project) do
      cycles = if params.ended, do: cycles, else: Enum.reject(cycles, &(&1.status == :ended))
      {:reply, Response.json(Response.tool(), CycleJSON.index(%{cycles: cycles})), frame}
    else
      {:error, reason} -> {:reply, mcp_error_response(reason), frame}
    end
  end

  defp read_cycles(%Project{} = project) do
    {:ok, %{cycles: cycles}} = Issues.get_cycles(project)
    {:ok, cycles}
  end
end
