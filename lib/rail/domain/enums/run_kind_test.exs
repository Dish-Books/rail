defmodule Rail.Domain.Enums.RunKindTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Enums.RunKind

  test "all/0 and values/0 contain stage, chat, improve" do
    expected = [:stage, :chat, :improve]
    assert RunKind.all() == expected
    assert RunKind.values() == expected
  end

  test "label/1 returns correct display labels" do
    assert RunKind.label(:stage) == "Stage"
    assert RunKind.label(:chat) == "Chat"
    assert RunKind.label(:improve) == "Improve"
    assert RunKind.label(:invalid) == nil
  end

  test "predicates test run kind" do
    assert RunKind.stage?(:stage)
    refute RunKind.stage?(:chat)
    refute RunKind.stage?(:invalid)

    assert RunKind.chat?(:chat)
    refute RunKind.chat?(:stage)
    refute RunKind.chat?(:invalid)

    assert RunKind.improve?(:improve)
    refute RunKind.improve?(:stage)
    refute RunKind.improve?(:invalid)
  end

  test "cast and dump work as expected" do
    assert RunKind.cast("stage") == {:ok, :stage}
    assert RunKind.cast("chat") == {:ok, :chat}
    assert RunKind.dump(:improve) == {:ok, "improve"}
    assert RunKind.load("improve") == {:ok, :improve}
  end
end
