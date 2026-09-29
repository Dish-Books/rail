defmodule Rail.Projects.Actions.ListSlackChannels do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.Project
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Repo

  @doc """
  The channels a project triages, or several projects' in one query, by name.
  """
  def list_slack_channels(%Project{id: project_id}) do
    Repo.all(from c in SlackChannel, where: c.project_id == ^project_id, order_by: [asc: c.name])
  end

  def list_slack_channels(projects) when is_list(projects) do
    ids = Enum.map(projects, fn %Project{id: id} -> id end)
    Repo.all(from c in SlackChannel, where: c.project_id in ^ids, order_by: [asc: c.name])
  end
end
