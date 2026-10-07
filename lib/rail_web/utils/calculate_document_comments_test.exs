defmodule RailWeb.Utils.CalculateDocumentCommentsTest do
  use ExUnit.Case, async: true

  import RailTest.Helpers
  import RailWeb.Utils.BuildDocumentBlocks
  import RailWeb.Utils.BuildPlanSheet
  import RailWeb.Utils.CalculateDocumentComments

  alias Rail.Pipeline.Schemas.PlanComment

  setup_all do
    comment = fn id, kind, text, occurrence ->
      %PlanComment{
        id: id,
        target: :ticket,
        element_kind: kind,
        element_text: text,
        element_occurrence: occurrence,
        element_label: "Paragraph",
        body: "Hm."
      }
    end

    %{comment: comment}
  end

  test "a comment stays under its line, the second of two that read the same included", %{comment: comment} do
    [first, _heading, second] = lines = build_document_blocks("Same.\n\n# Other\n\nSame.\n")
    on_second = comment.("pcm_1", :paragraph, "Same.", 2)
    on_first = comment.("pcm_2", :paragraph, "Same.", 1)

    placed = %{second.key => [{on_second, 1}], first.key => [{on_first, 2}]}
    assert %{placed: ^placed, lifted: []} = calculate_document_comments(lines, [{on_second, 1}, {on_first, 2}])
  end

  test "a comment whose copy is gone falls back to the first line that reads the same", %{comment: comment} do
    [only] = lines = build_document_blocks("Same.\n")
    numbered = {comment.("pcm_1", :paragraph, "Same.", 3), 1}

    assert %{placed: %{} = placed, lifted: []} = calculate_document_comments(lines, [numbered])
    assert placed[only.key] == [numbered]
  end

  test "two comments on one line come back in round order", %{comment: comment} do
    [line] = lines = build_document_blocks("Once.\n")
    one = {comment.("pcm_b", :paragraph, "Once.", 1), 2}
    other = {comment.("pcm_a", :paragraph, "Once.", 1), 3}

    assert %{placed: %{} = placed} = calculate_document_comments(lines, [one, other])
    assert placed[line.key] == [one, other]
  end

  test "a comment on a paragraph that changed is lifted, and one on a line that did not stays", %{comment: comment} do
    lines = build_document_blocks("Kept.\n\nRewritten since.\n")
    kept = {comment.("pcm_1", :paragraph, "Kept.", 1), 1}
    changed = {comment.("pcm_2", :paragraph, "As it read.", 1), 2}

    assert %{placed: placed, lifted: [^changed]} = calculate_document_comments(lines, [kept, changed])
    assert Map.values(placed) == [[kept]]
  end

  test "a comment on a diagram node stays while a node has its id" do
    %{lines: lines} = build_plan_sheet(sheet_plan())

    node = %PlanComment{id: "pcm_n", target: :plan, element_kind: :node, element_text: "SB", element_occurrence: 1}
    gone = %{node | id: "pcm_g", element_text: "Gone"}

    assert %{placed: placed, lifted: [{^gone, 2}]} = calculate_document_comments(lines, [{node, 1}, {gone, 2}])
    assert [[{^node, 1}]] = Map.values(placed)
  end
end
