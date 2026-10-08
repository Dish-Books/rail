defmodule RailWeb.Components.CommentableLineTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import RailWeb.Utils.BuildDocumentBlocks

  alias Rail.Pipeline.Schemas.PlanComment
  alias RailWeb.Components.CommentableLine

  setup_all do
    [paragraph, heading, item, table_header, _row, code, _second] =
      build_document_blocks("Para.\n\n## Head\n\n- Item\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\n```\none\ntwo\n```\n")

    comment = fn id, line ->
      %PlanComment{
        id: id,
        target: :ticket,
        element_kind: line.kind,
        element_text: line.text,
        element_label: line.label,
        element_occurrence: 1,
        body: "About #{id}."
      }
    end

    %{
      paragraph: paragraph,
      heading: heading,
      item: item,
      table_header: table_header,
      code: code,
      comment: comment
    }
  end

  test "a paragraph, a list item and a heading draw the + in the left gutter, naming the line", %{
    paragraph: paragraph,
    heading: heading,
    item: item
  } do
    for line <- [paragraph, heading, item] do
      html =
        (&CommentableLine.commentable_line/1)
        |> render_component(line: line, doc: :ticket, placed: %{}, offered: true, target: nil)
        |> Floki.parse_fragment!()

      assert [add] = Floki.find(html, "#line-ticket-#{line.key} > button[data-qa='line_comment_add']")
      assert Floki.attribute(add, "aria-label") == ["Comment on #{line.label}"]
      assert Floki.attribute(add, "phx-click") == ["open_document_comment"]
      assert Floki.attribute(add, "phx-value-key") == [line.key]
      assert Floki.attribute(add, "phx-value-doc") == ["ticket"]
      assert [class] = Floki.attribute(add, "class")
      assert class =~ "-left-6"
    end
  end

  test "a file entry drawn by the page keeps the gutter +" do
    assigns = %{line: %{key: "file-1", kind: :file, text: "lib/a.ex", label: "File 1", occurrence: 1, depth: 0}}

    html =
      ~H"""
      <CommentableLine.commentable_line line={@line} doc={:plan} placed={%{}} offered target={nil}>
        <code id="the-path">{@line.text}</code>
      </CommentableLine.commentable_line>
      """
      |> rendered_to_string()
      |> Floki.parse_fragment!()

    assert Floki.text(Floki.find(html, "#line-plan-file-1 #the-path")) == "lib/a.ex"
    assert [_add] = Floki.find(html, "#line-plan-file-1 [data-qa='line_comment_add']")
  end

  test "a code line draws the + over its number, which turns amber once it has a comment", %{
    code: code,
    comment: comment
  } do
    bare =
      (&CommentableLine.commentable_line/1)
      |> render_component(line: code, layout: :code, doc: :plan, placed: %{}, offered: true, target: nil)
      |> Floki.parse_fragment!()

    assert [class] = Floki.attribute(bare, "[data-qa='line_comment_add']", "class")
    assert class =~ "left-1"
    assert [number] = Floki.attribute(bare, "[data-qa='line_number']", "class")
    refute number =~ "amber"

    commented =
      (&CommentableLine.commentable_line/1)
      |> render_component(
        line: code,
        layout: :code,
        doc: :plan,
        placed: %{code.key => [{comment.("pcm_1", code), 4}]},
        offered: true,
        target: nil
      )
      |> Floki.parse_fragment!()

    assert [number] = Floki.attribute(commented, "[data-qa='line_number']", "class")
    assert number =~ "text-amber-700"
    assert Floki.text(Floki.find(commented, "[data-qa='document_comment_number']")) =~ "4"
  end

  test "the priority row draws each value's + in the row's gutter, outlines the hovered value and names it on a card",
       %{comment: comment} do
    priority = %{key: "priority-1", kind: :priority, text: "Medium", label: "Priority", occurrence: 1}
    estimate = %{key: "estimate-1", kind: :estimate, text: "3 Points", label: "Estimate", occurrence: 1}

    assigns = %{
      priority: priority,
      estimate: estimate,
      placed: %{"estimate-1" => [{comment.("pcm_e", estimate), 3}], "priority-1" => [{comment.("pcm_p", priority), 2}]}
    }

    html =
      ~H"""
      <CommentableLine.commentable_line
        layout={:values}
        doc={:ticket}
        placed={@placed}
        offered
        target={nil}
      >
        <:value line={@priority}>Medium</:value>
        <:value line={@estimate}>3 Points</:value>
      </CommentableLine.commentable_line>
      """
      |> rendered_to_string()
      |> Floki.parse_fragment!()

    assert [value_class, _estimate] = Floki.attribute(html, "[data-qa='commentable_value']", "class")
    assert value_class =~ "line-comment-value"

    assert ["Comment on Priority", "Comment on Estimate"] =
             Floki.attribute(html, "[data-qa='line_comment_add']", "aria-label")

    assert [class, _other] = Floki.attribute(html, "[data-qa='line_comment_add']", "class")
    assert class =~ "-left-6"

    assert ["Priority", "Estimate"] =
             html |> Floki.find("[data-qa='document_comment_line']") |> Enum.map(&String.trim(Floki.text(&1)))
  end

  test "a table row puts its comments and the box in a full-width row under it", %{
    table_header: header,
    comment: comment
  } do
    html =
      (&CommentableLine.commentable_line/1)
      |> render_component(
        line: header,
        layout: :table_row,
        doc: :ticket,
        placed: %{header.key => [{comment.("pcm_t", header), 1}]},
        draft: %{doc: :ticket, key: header.key, label: header.label, body: "Half"},
        offered: true,
        target: nil
      )
      |> Floki.parse_fragment!()

    assert [style] = Floki.attribute(html, "#line-ticket-#{header.key}", "style")
    assert style =~ "repeat(2, minmax(0, 1fr))"
    assert [under] = Floki.find(html, "[data-qa='line_comments']")
    assert [class] = Floki.attribute(under, "class")
    assert class =~ "border-t"
    assert [_card] = Floki.find(under, "[data-qa='document_comment']")
    assert [_box] = Floki.find(under, "form[data-qa='document_comment_form']")
    assert [class] = Floki.attribute(html, "[data-qa='line_comment_add']", "class")
    assert class =~ "-left-8"
  end

  test "a summary line keeps its comments inside its card", %{comment: comment} do
    line = %{key: "summary-1", kind: :summary, text: "2 files", label: "In this plan, line 1", occurrence: 1}
    assigns = %{line: line, placed: %{"summary-1" => [{comment.("pcm_s", line), 1}]}}

    html =
      ~H"""
      <div id="card">
        <CommentableLine.commentable_line
          line={@line}
          layout={:summary}
          doc={:plan}
          placed={@placed}
          offered
          target={nil}
        >
          2 files
        </CommentableLine.commentable_line>
      </div>
      """
      |> rendered_to_string()
      |> Floki.parse_fragment!()

    assert [_card] = Floki.find(html, "#card [data-qa='line_comments'] [data-qa='document_comment']")
    assert [class] = Floki.attribute(html, "[data-qa='line_comment_add']", "class")
    assert class =~ "-left-[26px]"
  end

  test "a line with two comments draws both, numbered in order, and still draws its +", %{
    paragraph: paragraph,
    comment: comment
  } do
    html =
      (&CommentableLine.commentable_line/1)
      |> render_component(
        line: paragraph,
        doc: :ticket,
        placed: %{paragraph.key => [{comment.("pcm_a", paragraph), 2}, {comment.("pcm_b", paragraph), 3}]},
        offered: true,
        target: nil
      )
      |> Floki.parse_fragment!()

    assert ["2", "3"] =
             html |> Floki.find("[data-qa='document_comment_number']") |> Enum.map(&String.trim(Floki.text(&1)))

    assert [_add] = Floki.find(html, "[data-qa='line_comment_add']")
    assert Floki.find(html, "[data-qa='document_comment_line']") == []
  end

  test "with commenting not offered no line draws a +, and the comments still show", %{
    paragraph: paragraph,
    code: code,
    table_header: header,
    comment: comment
  } do
    for {line, layout} <- [{paragraph, :text}, {code, :code}, {header, :table_row}] do
      html =
        (&CommentableLine.commentable_line/1)
        |> render_component(
          line: line,
          layout: layout,
          doc: :ticket,
          placed: %{line.key => [{comment.("pcm_x", line), 1}]},
          offered: false,
          target: nil
        )
        |> Floki.parse_fragment!()

      assert Floki.find(html, "[data-qa='line_comment_add']") == []
      assert [_card] = Floki.find(html, "[data-qa='document_comment']")
    end
  end

  test "a node draws nothing until it has a comment or the box, which name it under the figure", %{comment: comment} do
    node = %{key: "node-1", kind: :node, text: "PS", label: "Change diagram node", occurrence: 1}

    assert render_component(&CommentableLine.commentable_line/1,
             line: node,
             layout: :node,
             doc: :plan,
             placed: %{},
             offered: true,
             target: nil
           ) == ""

    html =
      (&CommentableLine.commentable_line/1)
      |> render_component(
        line: node,
        layout: :node,
        doc: :plan,
        placed: %{"node-1" => [{comment.("pcm_n", node), 1}]},
        offered: true,
        target: nil
      )
      |> Floki.parse_fragment!()

    assert Floki.text(Floki.find(html, "[data-qa='document_comment_line']")) =~ "Node PS"
    assert Floki.find(html, "[data-qa='line_comment_add']") == []
  end

  test "an ordered item, a task item, a nested item and a blockquote draw their own markers" do
    lines = build_document_blocks("2. Second\n\n- [x] Done\n  - Under it\n\n> Quoted\n")

    html =
      lines
      |> Enum.map_join(fn line ->
        render_component(&CommentableLine.commentable_line/1,
          line: line,
          doc: :ticket,
          placed: %{},
          offered: false,
          target: nil
        )
      end)
      |> Floki.parse_fragment!()

    assert Floki.text(html) =~ "2."
    assert Floki.find(html, ".pi-check-square") != []
    assert [_indented] = Floki.find(html, "[style='margin-left: 22px']")
    assert Floki.find(html, "[data-kind='blockquote'] .border-l-2") != []
  end
end
