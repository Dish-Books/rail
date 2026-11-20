defmodule Rail.Support.Schemas.ChatMessage do
  @moduledoc """
  A line in a conversation's chat with the support agent.
  """
  use Rail.Schema

  alias Rail.Support.Schemas.Conversation
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "sct"}
  schema "support_chat_messages" do
    field :author, Ecto.Enum, values: [:person, :agent]
    field :text, :string
    # What a pass changed in the draft, such as "Edited the reply · Added item 3".
    field :changes, :string

    belongs_to :conversation, Conversation
    belongs_to :user, User

    timestamps()
  end

  def person_changeset(%Conversation{id: conversation_id}, %User{id: user_id}, attrs) do
    %__MODULE__{conversation_id: conversation_id, user_id: user_id, author: :person}
    |> cast(attrs, [:text])
    |> update_change(:text, &String.trim/1)
    |> validate_required([:text])
    |> validate_length(:text, max: 4000)
  end
end
