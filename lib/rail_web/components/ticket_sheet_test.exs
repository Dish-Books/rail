defmodule RailWeb.Components.TicketSheetTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import RailWeb.Utils.BuildTicketLines

  alias RailWeb.Components.TicketSheet

  setup_all do
    ticket = %{title: "Previews", priority: :high, estimate: 3, description: "Slow.\n\n## Acceptance criteria\n\n- One\n"}
    %{ticket: ticket, lines: build_ticket_lines(ticket)}
  end

  test "with no comment state it draws the title, values and description with no + on any line", %{
    ticket: ticket,
    lines: lines
  } do
    html =
      (&TicketSheet.ticket_sheet/1)
      |> render_component(id: "review-ticket", ticket: ticket, lines: lines)
      |> Floki.parse_fragment!()

    assert Floki.attribute(html, "#review-ticket", "data-qa") == ["review_ticket"]
    assert Floki.text(Floki.find(html, "#review-ticket-title")) =~ "Previews"
    assert Floki.text(Floki.find(html, "#review-ticket-priority")) =~ "High"
    assert Floki.text(Floki.find(html, "#review-ticket-estimate")) =~ "3 Points"
    assert Floki.text(Floki.find(html, "#review-ticket-description")) =~ "One"
    assert Floki.find(html, "[data-qa='line_comment_add']") == []
  end

  test "offered, every line has its +", %{ticket: ticket, lines: lines} do
    html =
      (&TicketSheet.ticket_sheet/1)
      |> render_component(id: "plan-ticket", ticket: ticket, lines: lines, offered: true)
      |> Floki.parse_fragment!()

    # The title, the priority, the estimate, then the description's paragraph, heading and item.
    assert length(Floki.find(html, "[data-qa='line_comment_add']")) == 6
  end
end
