defmodule Rail.Pipeline.Schemas.Demo do
  @moduledoc """
  What a demo run says it filmed, as it stands on disk. There is no table behind
  this.

  Nothing rules on a demo the way a human rules on a finding, so there is nothing
  to survive a rewrite: the next recording replaces the last one whole, and a
  task has one demo, the current one. The demo saves it with `save_demo` and it is
  read off the file whenever the panel draws, the way the QA verdict and the
  approved design are.

  That does mean a demo is not history. Once the task is cleaned up the video
  goes with the scratch directory, and a merged task can no longer be asked what
  its walkthrough showed.

  The beats are not in here. They are stamped by Rail against the recording's own
  clock while the run is still going, so they are read separately and are there
  even for a run that never got as far as saving this.
  """
  use Rail.Schema

  @primary_key false
  embedded_schema do
    field :title, :string
    field :summary, :string
    field :not_shown, :string
    # The commit HEAD was on when the write-up was saved, which is Rail's to say.
    field :commit, :string
  end

  @doc """
  Builds a changeset for the write-up a demo run saved.
  """
  def changeset(demo, attrs) do
    demo
    |> cast(attrs, [:title, :summary, :not_shown])
    |> validate_required([:title, :summary])
  end
end
