defmodule Rail.Issues.Schemas.Comment do
  @moduledoc """
  A comment on an issue, mirrored from Linear. A reply points at the top-level
  comment it answers; Linear threads only one level deep.
  """
  use Rail.Schema

  alias Rail.Issues.Schemas.Issue
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "com"}
  schema "issue_comments" do
    field :external_id, :string
    field :body, :string, default: ""
    field :author_name, :string
    field :author_avatar_url, :string

    belongs_to :issue, Issue
    belongs_to :parent, __MODULE__
    belongs_to :author_user, User

    has_many :replies, __MODULE__, foreign_key: :parent_id

    timestamps()
  end

  @cast_fields [
    :author_avatar_url,
    :author_name,
    :author_user_id,
    :body,
    :external_id,
    :inserted_at,
    :issue_id,
    :parent_id,
    :updated_at
  ]

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, @cast_fields)
    |> validate_required([:issue_id, :external_id])
    |> unique_constraint(:external_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:author_user_id)
  end
end
