defmodule Rail.Initiatives.Schemas.InitiativeComment do
  @moduledoc "A comment on an initiative. Only update briefs post them for now."
  use Rail.Schema

  alias Rail.Initiatives.Schemas.Initiative
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "inc"}
  schema "initiative_comments" do
    field :body, :string

    belongs_to :initiative, Initiative
    belongs_to :author_user, User

    timestamps()
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body])
    |> validate_required([:body])
  end
end
