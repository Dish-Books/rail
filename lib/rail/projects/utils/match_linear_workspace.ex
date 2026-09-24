defmodule Rail.Projects.Utils.MatchLinearWorkspace do
  @moduledoc false

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  Points `project` at the workspace `attrs` names by external id, so a save updates
  that shared row instead of rewriting the one the project was on. An id no
  workspace has yet gets a new row; attrs naming none leave `project` as it is.
  """
  def match_linear_workspace(%Project{} = project, %{} = attrs) do
    workspace_attrs = attrs[:linear_workspace] || attrs["linear_workspace"] || %{}

    case workspace_attrs[:external_id] || workspace_attrs["external_id"] do
      external_id when is_binary(external_id) and external_id != "" ->
        %{project | linear_workspace: Repo.get_by(LinearWorkspace, external_id: external_id)}

      _no_external_id ->
        project
    end
  end
end
