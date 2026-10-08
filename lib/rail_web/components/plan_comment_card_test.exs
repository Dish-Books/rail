defmodule RailWeb.Components.PlanCommentCardTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.PlanComment
  alias RailWeb.Components.PlanCommentCard

  test "names the sender, the count, the option and each numbered comment with its selector and element" do
    round = %{
      count: 2,
      groups: "the design",
      sections: [
        %{
          target: :design,
          title: "Lanes by what they wait on",
          key: "waiting-lanes",
          comments: [
            %{
              number: 1,
              selector: "#lane-needs-you",
              text: "Needs you 3",
              tag: nil,
              body: "Say how long.\nNot only the count."
            },
            %{number: 2, selector: "#group-by-project", text: "", tag: "label", body: "Drop it."}
          ]
        }
      ]
    }

    html = render_component(&PlanCommentCard.plan_comment_card/1, id: "msg-3", sender: "Maya Kowalski", round: round)
    text = html |> Floki.parse_fragment!() |> Floki.text()

    assert text =~ "Maya Kowalski"
    assert text =~ "2 comments on the design"
    assert text =~ "Lanes by what they wait on"
    assert text =~ "waiting-lanes"
    assert text =~ ~s(#lane-needs-you)
    assert text =~ ~s("Needs you 3")
    assert text =~ "Say how long.\nNot only the count."
    assert text =~ "<label>"
    assert text =~ "Drop it."
  end

  test "a round on the design, the ticket and the plan draws each section and names them all" do
    design = %PlanComment{
      target: :design,
      option_key: "a",
      selector: "#x",
      element_text: "X",
      element_tag: "p",
      body: "One."
    }

    line = %PlanComment{
      target: :ticket,
      element_kind: :priority,
      element_label: "Priority",
      element_occurrence: 1,
      element_text: "Medium",
      body: "Make it High."
    }

    round =
      [design, line, %{line | target: :plan, element_kind: :file, element_label: "File 1", element_text: "lib/a.ex"}]
      |> PlanComment.calculate_message(%{options: [%{key: "a", title: "First"}]})
      |> PlanComment.parse_message()

    html =
      (&PlanCommentCard.plan_comment_card/1)
      |> render_component(id: "msg-1", sender: "Maya", round: round, identifier: "RAIL-82")
      |> Floki.parse_fragment!()

    assert Floki.text(html) =~ "3 comments on the design, the ticket and the plan"
    assert [first, ticket, plan] = Floki.find(html, "[data-qa='plan_comment_card_section']")
    assert Floki.text(first) =~ "First"
    assert Floki.text(ticket) =~ ~r/Ticket\s+RAIL-82/
    assert Floki.text(ticket) =~ ~s(Priority"Medium")
    assert Floki.text(ticket) =~ "Make it High."
    assert Floki.text(plan) =~ ~s(File 1"lib/a.ex")
  end
end
