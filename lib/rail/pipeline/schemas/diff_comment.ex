defmodule Rail.Pipeline.Schemas.DiffComment do
  @moduledoc """
  One person's comment on one line of a task's diff, for the engineer: unsent and
  theirs alone, then sent for everyone to see, then resolved once its author is
  satisfied.

  It is drawn under its line only while a line on the same side, at the same
  number, still reads `line_text`; otherwise it is lifted to the top of its file.
  One written in a single commit's view is drawn under its line only in that view.

  `context_text` is the code around the line as it read then, which the engineer
  and the rule learned from it are given, since the line itself may move.
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
    field :context_text, :string, default: ""
    # Old-side numbers differ between the views, so a removed line is only the same
    # line in the view it was written in; one commit's lines are only that commit's.
    field :filter, Ecto.Enum, values: [:branch, :uncommitted, :commit]
    # The commit whose view it was written in, which a merge's never is.
    field :commit, :string
    field :body, :string
    # Left out of the changeset, so only the actions that send or resolve move it.
    field :status, Ecto.Enum, values: [:unsent, :sent, :resolved], default: :unsent

    belongs_to :task, Task
    belongs_to :user, User

    timestamps()
  end

  @cast_fields [:path, :line_kind, :line, :line_text, :filter, :body]
  @sha ~r/\A[0-9a-f]{7,40}\z/

  # As much either side of the line as a finding's hunk shows beside it.
  @context 6

  @doc """
  Builds a changeset for a comment. The task and its author are set by the caller.
  """
  def changeset(diff_comment, attrs) do
    diff_comment
    |> cast(attrs, [:commit | @cast_fields -- [:line_text]])
    # A blank line is still a line, so its empty text is kept rather than nulled.
    |> cast(attrs, [:line_text, :context_text], empty_values: [])
    |> validate_required(@cast_fields -- [:line_text])
    |> validate_number(:line, greater_than: 0)
    |> validate_commit()
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  The lines around `row` in its hunk of `rows`, a file's diff rows: up to six
  either side, never past the hunk, each with its diff glyph and `row` marked `>`.
  """
  def calculate_context_text(rows, %{kind: :line, index: index}) do
    hunk =
      rows
      |> Enum.chunk_by(&(&1.kind == :line))
      |> Enum.find([], fn chunk -> Enum.any?(chunk, &match?(%{kind: :line, index: ^index}, &1)) end)

    case Enum.find_index(hunk, &(&1.index == index)) do
      focus when is_integer(focus) ->
        hunk
        |> Enum.slice(max(focus - @context, 0)..(focus + @context))
        |> Enum.map_join("\n", fn line ->
          marker = if line.index == index, do: ">", else: " "
          String.trim_trailing("#{marker} #{glyph(line.line_kind)} #{line.text}")
        end)

      nil ->
        ""
    end
  end

  defp validate_commit(changeset) do
    if get_field(changeset, :filter) == :commit,
      do: changeset |> validate_required([:commit]) |> validate_format(:commit, @sha),
      else: put_change(changeset, :commit, nil)
  end

  defp glyph(:added), do: "+"
  defp glyph(:deleted), do: "-"
  defp glyph(:context), do: " "
end
