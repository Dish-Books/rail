defmodule Rail.Triage.Schemas.MessageTest do
  use Rail.DataCase, async: true

  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Message.ItemLink

  setup do
    %{items: [%Item{key: "stuck-at-design", position: 1}, %Item{key: "wait-times", position: 2}]}
  end

  test "marks each passage with the position of the item it raised", %{items: items} do
    message = %Message{
      text: "Approved BILL-88 and it sits at Design. Separately: could Up next show wait times? Thanks!",
      item_links: [
        %ItemLink{item_key: "wait-times", change: :raised, passage: "could Up next show wait times?"},
        %ItemLink{item_key: "stuck-at-design", change: :raised, passage: "Approved BILL-88 and it sits at Design."}
      ]
    }

    assert [
             {"Approved BILL-88 and it sits at Design.", 1},
             {" Separately: ", nil},
             {"could Up next show wait times?", 2},
             {" Thanks!", nil}
           ] = Message.segments(message, items)
  end

  test "leaves a passage that is not in the text, or names no item, unmarked", %{items: items} do
    message = %Message{
      text: "Same thing on BILL-91.",
      item_links: [
        %ItemLink{item_key: "stuck-at-design", change: :widened, passage: "something the agent misquoted"},
        %ItemLink{item_key: "gone", change: :raised, passage: "BILL-91"},
        %ItemLink{item_key: "wait-times", change: :added, passage: nil}
      ]
    }

    assert [{"Same thing on BILL-91.", nil}] = Message.segments(message, items)
  end

  test "an overlapping passage keeps the first one", %{items: items} do
    message = %Message{
      text: "abc def",
      item_links: [
        %ItemLink{item_key: "stuck-at-design", passage: "abc d"},
        %ItemLink{item_key: "wait-times", passage: "c def"}
      ]
    }

    assert [{"abc d", 1}, {"ef", nil}] = Message.segments(message, items)
  end

  test "says whether a teammate posted it through Rail" do
    assert Message.via_rail?(%Message{sent_by_user_id: "usr_1"})
    refute Message.via_rail?(%Message{sent_by_user_id: nil})
  end
end
