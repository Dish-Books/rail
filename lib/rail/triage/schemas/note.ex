defmodule Rail.Triage.Schemas.Note do
  @moduledoc """
  A person's note on one item: context triage lacked, or a correction to
  something it assumed. It goes to the next pass of that item, never to Slack;
  what goes to Slack are replies.
  """
  use Rail.Schema

  alias Rail.Scope
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "tno"}
  schema "triage_notes" do
    field :text, :string
    # The assumption it answers, quoted as the item stated it, when it corrects one.
    field :assumption, :string

    belongs_to :thread, Thread
    belongs_to :item, Item
    belongs_to :user, User

    timestamps()
  end

  def changeset(%Scope{user: %{id: user_id}}, %Item{id: item_id, thread_id: thread_id}, attrs) do
    %__MODULE__{thread_id: thread_id, item_id: item_id, user_id: user_id}
    |> cast(attrs, [:text, :assumption])
    |> update_change(:text, &String.trim/1)
    |> validate_required([:text])
  end
end
