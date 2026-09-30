defmodule RailWeb.Components.DiffCommentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.DiffComment
  alias RailWeb.Components.DiffComment, as: Card

  test "under its line it is the comment alone, not yet sent" do
    comment = %{DiffComment.factory() | id: "dcm_placed", body: "Name this for what it does."}

    html = render_component(&Card.diff_comment/1, comment: comment)

    assert html =~ "Not sent"
    assert html =~ "Name this for what it does."
    refute html =~ "diff_comment_quote"
  end

  test "lifted off an unchanged line, it quotes the line as it read" do
    comment = %{DiffComment.factory() | id: "dcm_lifted", line_kind: :context, line: 39, line_text: "  filters = parse()"}

    html = render_component(&Card.diff_comment/1, comment: comment, lifted?: true)

    assert html =~ "Line 39 when you commented"
    assert [quote] = html |> Floki.parse_fragment!() |> Floki.find("[data-qa='diff_comment_quote']")
    assert Floki.text(quote) =~ "  filters = parse()"
  end
end
