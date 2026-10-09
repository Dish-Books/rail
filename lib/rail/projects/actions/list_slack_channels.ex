defmodule Rail.Projects.Actions.ListSlackChannels do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.Project
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Repo

  @doc """
  The channels a project triages, several projects' in one query, or a workspace's, by name.
  `external: true` lists every project's channels marked as shared outside the team.
  """
  def list_slack_channels([{:external, external}]) when is_boolean(external) do
    Repo.all(from c in SlackChannel, where: c.external == ^external, order_by: [asc: c.name])
  end

  def list_slack_channels(%Project{id: project_id}) do
    Repo.all(from c in SlackChannel, where: c.project_id == ^project_id, order_by: [asc: c.name])
  end

  def list_slack_channels(%SlackWorkspace{id: workspace_id}) do
    Repo.all(from c in SlackChannel, where: c.slack_workspace_id == ^workspace_id, order_by: [asc: c.name])
  end

  def list_slack_channels(projects) when is_list(projects) do
    ids = Enum.map(projects, fn %Project{id: id} -> id end)
    Repo.all(from c in SlackChannel, where: c.project_id in ^ids, order_by: [asc: c.name])
  end
end
