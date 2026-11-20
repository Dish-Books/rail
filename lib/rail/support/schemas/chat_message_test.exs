defmodule Rail.Support.Schemas.ChatMessageTest do
  use Rail.DataCase, async: true

  alias Rail.Support.Schemas.ChatMessage
  alias Rail.Support.Schemas.Conversation
  alias Rail.Users.Schemas.User

  test "a person's message is theirs, trimmed, on the conversation" do
    assert %Ecto.Changeset{
             valid?: true,
             data: %ChatMessage{conversation_id: "scv_1", user_id: "usr_1", author: :person},
             changes: %{text: "Drop the second paragraph"}
           } =
             ChatMessage.person_changeset(%Conversation{id: "scv_1"}, %User{id: "usr_1"}, %{
               "text" => "  Drop the second paragraph \n",
               "author" => "agent"
             })
  end

  test "a blank or overlong message is refused" do
    assert %{text: ["can't be blank"]} =
             errors_on(ChatMessage.person_changeset(%Conversation{id: "scv_1"}, %User{id: "usr_1"}, %{"text" => "  "}))

    assert %{text: ["should be at most 4000 character(s)"]} =
             errors_on(
               ChatMessage.person_changeset(%Conversation{id: "scv_1"}, %User{id: "usr_1"}, %{
                 "text" => String.duplicate("a", 4001)
               })
             )
  end
end
