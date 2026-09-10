defmodule Rail.Domain.Enums.TaskStageTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Enums.TaskStage

  test "all/0 and values/0 contain 10 pipeline stages in order" do
    expected = [
      :product,
      :design,
      :architect,
      :engineer,
      :review,
      :qa,
      :qa_lead,
      :demo,
      :ready_to_merge,
      :merged
    ]

    assert TaskStage.all() == expected
    assert TaskStage.values() == expected
  end

  test "label/1 returns correct human display labels" do
    assert TaskStage.label(:product) == "Product"
    assert TaskStage.label(:design) == "Design"
    assert TaskStage.label(:architect) == "Architect"
    assert TaskStage.label(:engineer) == "Engineer"
    assert TaskStage.label(:review) == "Review"
    assert TaskStage.label(:qa) == "QA"
    assert TaskStage.label(:qa_lead) == "QA Lead"
    assert TaskStage.label(:demo) == "Demo"
    assert TaskStage.label(:ready_to_merge) == "Ready to merge"
    assert TaskStage.label(:merged) == "Merged"
    assert TaskStage.label(:invalid) == nil
  end

  test "next_stage/1 walks the pipeline in order" do
    assert TaskStage.next_stage(:product) == :design
    assert TaskStage.next_stage(:design) == :architect
    assert TaskStage.next_stage(:architect) == :engineer
    assert TaskStage.next_stage(:engineer) == :review
    assert TaskStage.next_stage(:review) == :qa
    assert TaskStage.next_stage(:qa) == :qa_lead
    assert TaskStage.next_stage(:qa_lead) == :demo
    assert TaskStage.next_stage(:demo) == :ready_to_merge
    assert TaskStage.next_stage(:ready_to_merge) == :merged
    assert TaskStage.next_stage(:merged) == nil
    assert TaskStage.next_stage(:invalid) == nil
  end

  test "prev_stage/1 and previous_stage/1 walk backwards" do
    assert TaskStage.prev_stage(:product) == nil
    assert TaskStage.prev_stage(:design) == :product
    assert TaskStage.prev_stage(:architect) == :design
    assert TaskStage.prev_stage(:engineer) == :architect
    assert TaskStage.prev_stage(:review) == :engineer
    assert TaskStage.prev_stage(:qa) == :review
    assert TaskStage.prev_stage(:qa_lead) == :qa
    assert TaskStage.prev_stage(:demo) == :qa_lead
    assert TaskStage.prev_stage(:ready_to_merge) == :demo
    assert TaskStage.prev_stage(:merged) == :ready_to_merge
    assert TaskStage.prev_stage(:invalid) == nil

    assert TaskStage.previous_stage(:design) == :product
  end

  test "advanceable?/1 is true for all stages except merged" do
    assert TaskStage.advanceable?(:product)
    assert TaskStage.advanceable?(:design)
    assert TaskStage.advanceable?(:architect)
    assert TaskStage.advanceable?(:engineer)
    assert TaskStage.advanceable?(:review)
    assert TaskStage.advanceable?(:qa)
    assert TaskStage.advanceable?(:qa_lead)
    assert TaskStage.advanceable?(:demo)
    assert TaskStage.advanceable?(:ready_to_merge)

    refute TaskStage.advanceable?(:merged)
    refute TaskStage.advanceable?(:invalid)
    refute TaskStage.advanceable?(nil)
    refute TaskStage.advanceable?("product")
    refute TaskStage.advanceable?(123)
  end

  test "gate?/1 returns true only for review, qa, and qa_lead" do
    assert TaskStage.gate?(:review)
    assert TaskStage.gate?(:qa)
    assert TaskStage.gate?(:qa_lead)

    refute TaskStage.gate?(:product)
    refute TaskStage.gate?(:engineer)
    refute TaskStage.gate?(:demo)
    refute TaskStage.gate?(:merged)
    refute TaskStage.gate?(:invalid)
    refute TaskStage.gate?("review")
    refute TaskStage.gate?(nil)
  end

  test "terminal?/1 returns true only for merged" do
    assert TaskStage.terminal?(:merged)
    refute TaskStage.terminal?(:ready_to_merge)
    refute TaskStage.terminal?(:invalid)
    refute TaskStage.terminal?("merged")
    refute TaskStage.terminal?(nil)
  end

  test "index/1 returns 0-indexed positions" do
    assert TaskStage.index(:product) == 0
    assert TaskStage.index(:design) == 1
    assert TaskStage.index(:architect) == 2
    assert TaskStage.index(:engineer) == 3
    assert TaskStage.index(:review) == 4
    assert TaskStage.index(:qa) == 5
    assert TaskStage.index(:qa_lead) == 6
    assert TaskStage.index(:demo) == 7
    assert TaskStage.index(:ready_to_merge) == 8
    assert TaskStage.index(:merged) == 9
    assert TaskStage.index(:invalid) == nil
  end

  test "before?/2 and after?/2 compare positions in pipeline" do
    assert TaskStage.before?(:product, :engineer)
    assert TaskStage.before?(:review, :merged)
    refute TaskStage.before?(:engineer, :product)
    refute TaskStage.before?(:product, :product)
    refute TaskStage.before?(:invalid, :engineer)
    refute TaskStage.before?(:product, :invalid)
    refute TaskStage.before?("product", :engineer)
    refute TaskStage.before?(:product, "engineer")

    assert TaskStage.after?(:merged, :ready_to_merge)
    assert TaskStage.after?(:engineer, :product)
    refute TaskStage.after?(:product, :engineer)
    refute TaskStage.after?(:product, :product)
    refute TaskStage.after?(:invalid, :engineer)
    refute TaskStage.after?(:product, :invalid)
    refute TaskStage.after?("merged", :ready_to_merge)
    refute TaskStage.after?(:merged, "ready_to_merge")
  end

  test "casting and loading handle camelCase and snake_case strings" do
    assert TaskStage.cast("ready_to_merge") == {:ok, :ready_to_merge}
    assert TaskStage.cast("readyToMerge") == {:ok, :ready_to_merge}
    assert TaskStage.cast("qaLead") == {:ok, :qa_lead}
    assert TaskStage.cast("qa_lead") == {:ok, :qa_lead}

    assert TaskStage.load("ready_to_merge") == {:ok, :ready_to_merge}
    assert TaskStage.dump(:ready_to_merge) == {:ok, "ready_to_merge"}
  end
end
