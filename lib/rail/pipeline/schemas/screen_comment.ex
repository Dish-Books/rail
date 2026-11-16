defmodule Rail.Pipeline.Schemas.ScreenComment do
  @moduledoc """
  One person's comment on one screen state Review shot, for the Review lead: unsent and theirs alone, then sent, after
  which it reads only in the message it went out in. It is on the state, not a picture, since a retake replaces it.

  A comment with `source: :app` is on one element of the task's app as a person used it inside Rail: its `label` is
  the page's path, its `selector` names the element in the grammar design comments use, and its picture is of the
  element as it was.
  """
  use Rail.Schema

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Users.Schemas.User

  @key ~r/\A[a-z0-9][a-z0-9-]{0,59}\z/
  # The grammar a design comment's selector keeps to: ids, tags and `:nth-child(n)` steps.
  @selector ~r/\A[A-Za-z0-9_#:()> -]+\z/

  @primary_key {:id, UXID, autogenerate: true, prefix: "scm"}
  schema "screen_comments" do
    field :key, :string
    # The state's label and the commit of its shot when the comment was written, set from the shot, never the client.
    field :label, :string
    field :commit, :string
    field :body, :string
    # Left out of the changeset, so only sending moves it.
    field :status, Ecto.Enum, values: [:unsent, :sent], default: :unsent
    field :source, Ecto.Enum, values: [:shot, :app], default: :shot
    field :selector, :string
    field :element_text, :string
    field :element_tag, :string
    # Where Rail saved the element's picture in the task's scratch; set by Rail, never the client.
    field :picture_path, :string

    belongs_to :task, Task
    belongs_to :user, User

    timestamps()
  end

  @doc """
  Builds a changeset for a comment on the state `key`. The task, its author, the label and the commit are set by the
  caller.
  """
  def changeset(screen_comment, attrs) do
    screen_comment
    |> cast(attrs, [:key, :body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:key, :body])
    |> validate_format(:key, @key)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Builds a changeset for a comment on an element of the running app. The task, its author, the commit, the page's
  path as `label` and the picture are set by the caller, from what Rail's browser saw.
  """
  def app_changeset(screen_comment, attrs) do
    screen_comment
    |> cast(attrs, [:body, :selector, :element_text, :element_tag])
    |> put_change(:source, :app)
    |> put_change(:key, "app")
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body, :selector, :label])
    |> validate_format(:selector, @selector)
    |> validate_length(:selector, max: 1000)
    |> validate_length(:element_text, max: 200)
    |> validate_length(:element_tag, max: 64)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Builds a changeset that changes only the comment's text, for its author editing it before it is sent.
  """
  def edit_changeset(%__MODULE__{} = comment, attrs) do
    comment
    |> cast(attrs, [:body])
    # A blank text casts to nil, which is refused below.
    |> update_change(:body, &(&1 && String.trim(&1)))
    |> validate_required([:body])
  end

  @doc """
  Writes `comment` as the block the Review lead is sent. `screen` is its state as `Rail.Pipeline.list_screens/1` reads
  it at Send, or nil once no picture of it is left, and `scratch_path` the task's, whose QA folder holds the picture.
  """
  def calculate_block(%__MODULE__{source: :app} = comment, _screen, _scratch_path) do
    on = if comment.commit, do: ", commented on #{short(comment.commit)}", else: ""
    said = if comment.element_text in [nil, ""], do: comment.element_tag, else: ~s("#{comment.element_text}")

    lines = [
      "<app_comment>",
      "In the running app at #{comment.label}#{on}",
      "Element: `#{comment.selector}` #{said}",
      comment.picture_path && "Picture: #{comment.picture_path}",
      comment.body,
      "</app_comment>"
    ]

    lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  def calculate_block(%__MODULE__{} = comment, screen, scratch_path) do
    on = if comment.commit, do: ", commented on #{short(comment.commit)}", else: ""

    lines = [
      "<screen_comment>",
      "#{comment.label} (#{comment.key})#{on}",
      picture(comment, screen, scratch_path),
      comment.body,
      "</screen_comment>"
    ]

    lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  defp picture(%__MODULE__{}, nil, _scratch_path), do: nil

  # A retake since the comment was written moved the picture on, so the lead is told which commit it shows now.
  defp picture(%__MODULE__{commit: commit}, %{file: file, commit: now}, scratch_path) do
    retaken = if is_binary(now) and now != commit, do: ", retaken on #{short(now)}", else: ""
    "Picture: #{Path.join([scratch_path, "qa", file])}#{retaken}"
  end

  defp short(commit), do: String.slice(commit, 0, 7)
end
