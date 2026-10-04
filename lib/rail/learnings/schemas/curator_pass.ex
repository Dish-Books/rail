defmodule Rail.Learnings.Schemas.CuratorPass do
  @moduledoc """
  One daily curator pass over a project: when it ran, whether it finished, and
  where its digest was posted.
  """
  use Rail.Schema

  alias Rail.Projects.Schemas.Project

  @primary_key {:id, UXID, autogenerate: true, prefix: "cps"}
  schema "curator_passes" do
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :error, :string
    field :digest_permalink, :string

    belongs_to :project, Project

    timestamps()
  end
end
