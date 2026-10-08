defmodule RailWeb.Components.DocumentCommentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.PlanComment
  alias RailWeb.Components.DocumentComment

  setup_all do
    comment = %PlanComment{
      id: "pcm_1",
      target: :ticket,
      element_kind: :priority,
      element_label: "Priority",
      element_text: "Medium",
      element_occurrence: 1,
      body: "This blocks the release notes. Make it High."
    }

    %{comment: comment}
  end

  test "an unsent card shows its tray number, Not sent, its body and Remove", %{comment: comment} do
    html =
      (&DocumentComment.document_comment/1)
      |> render_component(comment: comment, number: 2, target: nil)
      |> Floki.parse_fragment!()

    assert [card] = Floki.find(html, "#document-comment-pcm_1")
    assert Floki.attribute(card, "[data-qa='document_comment_number']", "aria-label") == ["Comment 2"]
    assert Floki.text(card) =~ "Not sent"
    assert Floki.text(card) =~ "This blocks the release notes. Make it High."
    assert Floki.attribute(card, "[data-qa='document_comment_remove']", "phx-value-id") == ["pcm_1"]
    assert Floki.attribute(card, "[data-qa='document_comment_remove']", "phx-click") == ["remove_plan_comment"]
    assert Floki.find(card, "[data-qa='document_comment_line']") == []
  end

  test "a card under the priority row names Priority, and one under a figure names its node", %{comment: comment} do
    priority =
      (&DocumentComment.document_comment/1)
      |> render_component(comment: comment, number: 2, named: true, target: nil)
      |> Floki.parse_fragment!()

    assert String.trim(Floki.text(Floki.find(priority, "[data-qa='document_comment_line']"))) == "Priority"

    node = %{comment | element_kind: :node, element_label: "Change diagram node", element_text: "PageSettled"}

    named =
      (&DocumentComment.document_comment/1)
      |> render_component(comment: node, number: 9, named: true, target: nil)
      |> Floki.parse_fragment!()

    assert String.trim(Floki.text(Floki.find(named, "[data-qa='document_comment_line']"))) == "Node PageSettled"
  end

  test "a lifted card adds Changed and quotes its line as it read", %{comment: comment} do
    html =
      (&DocumentComment.document_comment/1)
      |> render_component(comment: comment, number: 2, lifted: true, target: nil)
      |> Floki.parse_fragment!()

    assert Floki.attribute(html, "#document-comment-pcm_1", "data-lifted") == ["true"]
    assert Floki.text(Floki.find(html, "[data-qa='document_comment_changed']")) =~ "Changed"
    assert Floki.text(Floki.find(html, "[data-qa='document_comment_quote']")) == "Medium"
    assert Floki.text(html) =~ "Priority as you commented on it"
    assert Floki.attribute(html, "[data-qa='document_comment_remove']", "phx-value-id") == ["pcm_1"]
  end
end
