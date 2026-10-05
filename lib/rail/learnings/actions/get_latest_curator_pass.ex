defmodule Rail.Learnings.Actions.GetLatestCuratorPass do
  @moduledoc false

  import Ecto.Query

  alias Rail.Learnings.Schemas.CuratorPass
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  The latest finished pass on `project` that posted a digest, for the page's
  link to it. A quiet day posts none, so this can be an earlier day's.
  """
  def get_latest_curator_pass(%Project{id: project_id}) do
    query =
      from p in CuratorPass,
        where: p.project_id == ^project_id and not is_nil(p.finished_at) and not is_nil(p.digest_permalink),
        order_by: [desc: p.started_at, desc: p.id],
        limit: 1

    case Repo.one(query) do
      %CuratorPass{} = pass -> {:ok, pass}
      nil -> {:error, :not_found}
    end
  end
end
