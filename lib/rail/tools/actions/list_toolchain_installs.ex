defmodule Rail.Tools.Actions.ListToolchainInstalls do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Tools.Schemas.ToolchainInstall

  @doc """
  The toolchain installs worth showing, oldest first, each with its project:
  those queued or going, and a failed one for as long as it is its project's latest.
  """
  def list_toolchain_installs do
    latest = from(i in ToolchainInstall, group_by: i.project_id, select: max(i.id))

    Repo.all(
      from i in ToolchainInstall,
        where: i.status in [:queued, :installing] or (i.status == :failed and i.id in subquery(latest)),
        order_by: [asc: i.id],
        preload: :project
    )
  end
end
