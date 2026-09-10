defmodule Rail.Domain.Enums.QuestionStatusTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Enums.QuestionStatus

  test "all/0 and values/0 contain pending, answered, dismissed" do
    expected = [:pending, :answered, :dismissed]
    assert QuestionStatus.all() == expected
    assert QuestionStatus.values() == expected
  end

  test "label/1 returns correct display labels" do
    assert QuestionStatus.label(:pending) == "Pending"
    assert QuestionStatus.label(:answered) == "Answered"
    assert QuestionStatus.label(:dismissed) == "Dismissed"
    assert QuestionStatus.label(:invalid) == nil
  end

  test "pending?/1 and resolved?/1 predicates" do
    assert QuestionStatus.pending?(:pending)
    refute QuestionStatus.pending?(:answered)
    refute QuestionStatus.pending?(:invalid)
    refute QuestionStatus.pending?("pending")
    refute QuestionStatus.pending?(nil)

    assert QuestionStatus.resolved?(:answered)
    assert QuestionStatus.resolved?(:dismissed)
    refute QuestionStatus.resolved?(:pending)
    refute QuestionStatus.resolved?(:invalid)
    refute QuestionStatus.resolved?("answered")
    refute QuestionStatus.resolved?(nil)
  end

  test "cast and dump work as expected" do
    assert QuestionStatus.cast("pending") == {:ok, :pending}
    assert QuestionStatus.cast("answered") == {:ok, :answered}
    assert QuestionStatus.dump(:pending) == {:ok, "pending"}
    assert QuestionStatus.load("dismissed") == {:ok, :dismissed}
  end
end
