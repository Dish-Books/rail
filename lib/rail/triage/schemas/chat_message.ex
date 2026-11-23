defmodule Rail.Triage.Schemas.ChatMessage do
  @moduledoc """
  A line in a thread's chat with the triage agent.
  """
  use Rail.Schema

  alias Rail.Triage.Schemas.Thread
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "tct"}
  schema "triage_chat_messages" do
    field :author, Ecto.Enum, values: [:person, :agent]
    field :text, :string
    # What a pass changed, such as "Edited the reply · Removed item 3".
    field :changes, :string

    belongs_to :thread, Thread
    belongs_to :user, User

    timestamps()
  end

  def person_changeset(%Thread{id: thread_id}, %User{id: user_id}, attrs) do
    %__MODULE__{thread_id: thread_id, user_id: user_id, author: :person}
    |> cast(attrs, [:text])
    |> update_change(:text, &String.trim/1)
    |> validate_required([:text])
    |> validate_length(:text, max: 4000)
  end
end
