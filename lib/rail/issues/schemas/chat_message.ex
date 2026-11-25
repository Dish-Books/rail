defmodule Rail.Issues.Schemas.ChatMessage do
  @moduledoc """
  A line in an issue's chat with the agent, before the issue is started.
  """
  use Rail.Schema

  alias Rail.Issues.Schemas.Issue
  alias Rail.Users.Schemas.User

  @primary_key {:id, UXID, autogenerate: true, prefix: "icm"}
  schema "issue_chat_messages" do
    field :author, Ecto.Enum, values: [:person, :agent]
    field :text, :string
    # What the pass changed on the ticket, such as "Edited the title · Changed the estimate".
    field :changes, :string

    belongs_to :issue, Issue
    belongs_to :user, User

    timestamps()
  end

  def person_changeset(%Issue{id: issue_id}, %User{id: user_id}, attrs) do
    %__MODULE__{issue_id: issue_id, user_id: user_id, author: :person}
    |> cast(attrs, [:text])
    |> update_change(:text, &String.trim/1)
    |> validate_required([:text])
    |> validate_length(:text, max: 4000)
  end
end
