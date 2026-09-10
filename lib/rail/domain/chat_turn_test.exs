defmodule Rail.Domain.ChatTurnTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.ChatTurn
  alias Rail.Domain.HandoffLine

  test "changeset/2 validates required fields and syncs content/text" do
    valid_changeset =
      ChatTurn.changeset(%ChatTurn{}, %{
        role: :user,
        content: "Hello agent",
        usage: %{input_tokens: 10}
      })

    assert valid_changeset.valid?
    turn = apply_changes(valid_changeset)
    assert turn.text == "Hello agent"
    assert turn.usage.input_tokens == 10

    invalid_changeset = ChatTurn.changeset(%ChatTurn{}, %{role: nil, content: nil})
    refute invalid_changeset.valid?
    assert "can't be blank" in errors_on(invalid_changeset).role
    assert "can't be blank" in errors_on(invalid_changeset).content

    sync_from_text = ChatTurn.changeset(%ChatTurn{}, %{role: :agent, text: "from text"})
    assert sync_from_text.valid?
    assert apply_changes(sync_from_text).content == "from text"

    both_set = ChatTurn.changeset(%ChatTurn{}, %{role: :user, content: "both", text: "both"})
    assert both_set.valid?
  end

  test "factory/0 returns a valid fixture struct" do
    turn = ChatTurn.factory()
    assert turn.role == :user
    assert turn.author == :human
    assert turn.content =~ "primary button color"
    assert %DateTime{} = turn.timestamp
  end

  test "role helpers user?/1, agent?/1, system?/1" do
    user_turn = %ChatTurn{role: :user}
    agent_turn = %ChatTurn{role: :agent}
    sys_turn = %ChatTurn{role: :system}

    assert ChatTurn.user?(user_turn)
    refute ChatTurn.user?(agent_turn)
    refute ChatTurn.user?(:other)

    assert ChatTurn.agent?(agent_turn)
    refute ChatTurn.agent?(user_turn)
    refute ChatTurn.agent?(:other)

    assert ChatTurn.system?(sys_turn)
    refute ChatTurn.system?(user_turn)
    refute ChatTurn.system?(:other)
  end

  test "author helpers human?/1, role?/1, activity?/1, event?/1" do
    human_turn = %ChatTurn{author: :human}
    role_turn = %ChatTurn{author: :role}
    act_turn = %ChatTurn{author: :activity}
    event_turn = %ChatTurn{author: :event}

    assert ChatTurn.human?(human_turn)
    refute ChatTurn.human?(role_turn)
    refute ChatTurn.human?(:other)

    assert ChatTurn.role?(role_turn)
    refute ChatTurn.role?(human_turn)
    refute ChatTurn.role?(:other)

    assert ChatTurn.activity?(act_turn)
    refute ChatTurn.activity?(role_turn)
    refute ChatTurn.activity?(:other)

    assert ChatTurn.event?(event_turn)
    refute ChatTurn.event?(act_turn)
    refute ChatTurn.event?(:other)
  end

  test "handoff_role_id/1 extracts role_id or returns nil" do
    handoff = %HandoffLine{role_id: "architect", summary: "plan"}
    turn_with_handoff = %ChatTurn{handoff: handoff}
    turn_without_handoff = %ChatTurn{}

    assert ChatTurn.handoff_role_id(turn_with_handoff) == "architect"
    assert is_nil(ChatTurn.handoff_role_id(turn_without_handoff))
  end
end
