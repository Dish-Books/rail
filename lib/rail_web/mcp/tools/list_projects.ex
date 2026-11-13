defmodule RailWeb.Mcp.Tools.ListProjects do
  @moduledoc "Lists the projects you can open, with the key each of their ticket identifiers starts with."

  use Anubis.Server.Component, type: :tool, annotations: %{readOnlyHint: true}

  alias Anubis.Server.Response
  alias Rail.Projects
  alias RailWeb.Mcp.ProjectJSON

  schema do
  end

  @impl true
  def execute(_params, %{assigns: %{current_scope: scope}} = frame) do
    {:reply, Response.json(Response.tool(), ProjectJSON.index(%{projects: Projects.list_projects(scope)})), frame}
  end
end
