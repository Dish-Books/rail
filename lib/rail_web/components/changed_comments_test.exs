defmodule RailWeb.Components.ChangedCommentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.PlanComment
  alias RailWeb.Components.ChangedComments

  test "lifted comments draw dashed at the top, in round order, and none draws nothing" do
    comment = %PlanComment{
      id: "pcm_1",
      target: :ticket,
      element_kind: :paragraph,
      element_label: "Paragraph 1",
      element_text: "QA starts recording at first paint.",
      element_occurrence: 1,
      body: "Say which pages."
    }

    html =
      (&ChangedComments.changed_comments/1)
      |> render_component(id: "ticket-changed", comments: [{comment, 2}, {%{comment | id: "pcm_2"}, 4}], target: nil)
      |> Floki.parse_fragment!()

    assert ["pcm_1", "pcm_2"] =
             html
             |> Floki.find("#ticket-changed [data-lifted='true']")
             |> Enum.map(&(&1 |> Floki.attribute("id") |> hd() |> String.replace_prefix("document-comment-", "")))

    assert render_component(&ChangedComments.changed_comments/1, id: "none", comments: [], target: nil) == ""
  end
end
