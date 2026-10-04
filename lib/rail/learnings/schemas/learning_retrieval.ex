defmodule Rail.Learnings.Schemas.LearningRetrieval do
  @moduledoc """
  One rule a run was given when it started, once per pair however often it starts.
  """
  use Rail.Schema

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Pipeline.Schemas.Run

  @primary_key {:id, UXID, autogenerate: true, prefix: "lrt"}
  schema "learning_retrievals" do
    belongs_to :learning, Learning
    belongs_to :run, Run

    timestamps(updated_at: false)
  end
end
