defmodule RailWeb.Components.PlanCommentCardTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.PlanCommentCard

  test "names the sender, the count, the option and each numbered comment with its selector and element" do
    round = %{
      count: 2,
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
end
