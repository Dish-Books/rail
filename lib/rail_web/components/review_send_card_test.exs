defmodule RailWeb.Components.ReviewSendCardTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.FixPlan
  alias RailWeb.Components.ReviewSendCard

  test "a Send reads what it sent, with a row for each finding and numbered comment" do
    sent =
      FixPlan.parse_note("""
      Sent 2 findings and 1 comment.

      <finding key="send-drops" severity="blocker" kind="code">
      Send leaves screen comments out of the round
      </finding>

      <finding key="tray-count" severity="minor" kind="screen">
      Tray count leaves out finding comments
      </finding>

      1. On the diff:
      <diff_comment>
      lib/diff_comment.ex, line 58
      + hide(comment)
      Keep the sent comment under its line with Resolve.
      </diff_comment>
      """)

    doc =
      (&ReviewSendCard.review_send_card/1)
      |> render_component(id: "msg-3", sender: "You", sent: sent)
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("[data-qa=review_send_card_summary]") |> Floki.text() =~ "sent 2 findings and 1 comment"

    assert [
             "Send leaves screen comments out of the round",
             "Tray count leaves out finding comments",
             "1 Keep the sent comment under its line with Resolve."
           ] =
             doc
             |> Floki.find("[data-qa=review_send_card_row]")
             |> Enum.map(&(&1 |> Floki.text() |> String.split() |> Enum.join(" ")))
  end

  test "a Send of a changed ruling reads the finding's title and both rulings" do
    sent =
      FixPlan.parse_note("""
      Sent 1 changed ruling.

      <ruling_change key="tray-count" was="Fix" now="Don't fix">
      Tray count leaves out finding comments
      </ruling_change>
      """)

    doc =
      (&ReviewSendCard.review_send_card/1)
      |> render_component(id: "msg-4", sender: "You", sent: sent)
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("[data-qa=review_send_card_summary]") |> Floki.text() =~ "sent 1 changed ruling"

    assert doc |> Floki.find("[data-qa=review_send_card_row]") |> Floki.text() =~
             "Tray count leaves out finding comments · Don't fix, was Fix"
  end
end
