defmodule RailWeb.Components.ScreenCommentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.ScreenComment

  test "the card reads You, Not sent and the text, with Remove" do
    doc =
      (&RailWeb.Components.ScreenComment.screen_comment/1)
      |> render_component(comment: %ScreenComment{id: "scm_1", body: "It wraps\nat 1280px."}, target: nil)
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#screen-comment-scm_1") |> Floki.text() =~
             ~r/You\s+Not sent\s+Remove\s+It wraps\nat 1280px./

    assert ["scm_1"] = doc |> Floki.find("[data-qa=screen_comment_remove]") |> Floki.attribute("phx-value-id")
  end
end
