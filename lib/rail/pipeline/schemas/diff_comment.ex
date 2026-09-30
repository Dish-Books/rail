defmodule Rail.Pipeline.Schemas.DiffComment do
  @moduledoc """
  One person's unsent comment on one line of a task's diff, for the engineer.

  It is drawn under its line only while a line on the same side, at the same
  number, still reads `line_text`; otherwise it is lifted to the top of its file.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "dcm"}
  schema "diff_comments" do
    field :path, :string
    # `line` is the old file's number for a removed line and the new file's otherwise.
    field :line_kind, Ecto.Enum, values: [:added, :deleted, :context]
    field :line, :integer
    field :line_text, :string, default: ""
    # Old-side numbers differ between the two views, so a removed line is only
    # the same line in the view it was written in.
    field :filter, Ecto.Enum, values: [:branch, :uncommitted]
    field :body, :string

    belongs_to :task, Task
    belongs_to :user, User

    timestamps()
  end

  @cast_fields [:path, :line_kind, :line, :line_text, :filter, :body]

  @doc """
  Builds a changeset for a comment. The task and its author are set by the caller.
  """
  def changeset(diff_comment, attrs) do
    diff_comment
    |> cast(attrs, @cast_fields -- [:line_text])
    # A blank line is still a line, so its empty text is kept rather than nulled.
    |> cast(attrs, [:line_text], empty_values: [])
    |> validate_required(@cast_fields -- [:line_text])
    |> validate_number(:line, greater_than: 0)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:user_id)
  end

  def factory do
    %__MODULE__{
      path: "lib/rail/feature.ex",
      line_kind: :added,
      line: 1,
      line_text: "def feature, do: :ok",
      filter: :branch,
      body: "Name this for what it does."
    }
  end
end
