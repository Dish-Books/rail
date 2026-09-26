defmodule Rail.Projects.Actions.ListSlackChannels do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.Project
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Repo

  def list_slack_channels(%Project{id: project_id}) do
    Repo.all(from c in SlackChannel, where: c.project_id == ^project_id, order_by: [asc: c.name])
  end
end
