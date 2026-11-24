defmodule Rail.Triage.Schemas.ChatMessageTest do
  use Rail.DataCase, async: true

  alias Rail.Triage.Schemas.ChatMessage
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users.Schemas.User

  test "a person's line is theirs, trimmed, on the thread" do
    assert %Ecto.Changeset{
             valid?: true,
             data: %ChatMessage{thread_id: "tth_1", user_id: "usr_1", author: :person},
             changes: %{text: "Merge 2 and 3"}
           } =
             ChatMessage.person_changeset(%Thread{id: "tth_1"}, %User{id: "usr_1"}, %{
               "text" => "  Merge 2 and 3 \n",
               "author" => "agent"
             })
  end

  test "a blank or overlong line is refused" do
    assert %{text: ["can't be blank"]} =
             errors_on(ChatMessage.person_changeset(%Thread{id: "tth_1"}, %User{id: "usr_1"}, %{"text" => "  "}))

    assert %{text: ["should be at most 4000 character(s)"]} =
             errors_on(
               ChatMessage.person_changeset(%Thread{id: "tth_1"}, %User{id: "usr_1"}, %{
                 "text" => String.duplicate("a", 4001)
               })
             )
  end
end
