defmodule Rail.Git.Schemas.ViewedFile do
  @moduledoc """
  One file of a task's diff, marked read by one person.

  A row per person per file is what makes "have I read this" mean anything with
  more than one reviewer.

  The digest is the one the file had when it was read, and it is the whole of
  what makes a mark stand or lapse: a file the engineer has since touched hashes
  differently and reads unviewed again, so nothing has to reconcile these rows
  when the diff moves. It is also what tells the two views apart, since a file's
  branch diff and its uncommitted diff are different text.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "vwf"}
  schema "viewed_files" do
    field :path, :string
    field :digest, :string
    field :viewed_at, :utc_datetime_usec

    belongs_to :task, Task
    belongs_to :user, User

    timestamps()
  end

  @cast_fields [
    :task_id,
    :user_id,
    :path,
    :digest,
    :viewed_at
  ]

  @doc """
  Builds a changeset for a viewed file.
  """
  def changeset(viewed_file, attrs) do
    viewed_file
    |> cast(attrs, @cast_fields)
    |> validate_required(@cast_fields)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:task_id, :user_id, :path])
  end
end
