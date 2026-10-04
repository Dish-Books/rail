defmodule Rail.Learnings.Schemas.ProcessedPullRequest do
  @moduledoc """
  A pull request whose review comments have been read, so it is never fetched again.
  """
  use Rail.Schema

  alias Rail.Projects.Schemas.Project

  @primary_key {:id, UXID, autogenerate: true, prefix: "ppr"}
  schema "processed_pull_requests" do
    field :number, :integer

    belongs_to :project, Project

    timestamps(updated_at: false)
  end
end
