defmodule RailWeb.Components.PlanCommentTrayTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.PlanComment
  alias RailWeb.Components.PlanCommentTray

  setup do
    comments = [
      %PlanComment{
        id: "pcm_1",
        target: :design,
        selector: "#lane-needs-you > header:nth-child(1) > h2:nth-child(2)",
        element_text: "Needs you 3",
        element_tag: "h2",
        body: "Say how long the oldest one has waited."
      },
      %PlanComment{
        id: "pcm_2",
        target: :design,
        selector: "#group-by-project",
        element_text: "",
        element_tag: "label",
        body: "Drop it."
      }
    ]

    %{comments: comments}
  end

  test "design rows show their number, selector, quoted text or tag, comment and Remove", %{comments: comments} do
    html =
      render_component(&PlanCommentTray.plan_comment_tray/1,
        comments: comments,
        can_send: true,
        plan_running: false,
        target: nil
      )

    doc = Floki.parse_fragment!(html)

    [first] = Floki.find(doc, "#plan-comment-pcm_1")
    assert Floki.text(first) =~ "1"
    assert Floki.text(first) =~ "#lane-needs-you > header:nth-child(1) > h2:nth-child(2)"
    assert Floki.text(first) =~ ~s("Needs you 3")
    assert Floki.text(first) =~ "Say how long the oldest one has waited."
    assert Floki.attribute(first, "data-found") == ["true"]
    assert first |> Floki.find("[data-qa='remove_plan_comment']") |> Floki.attribute("phx-value-id") == ["pcm_1"]

    [second] = Floki.find(doc, "#plan-comment-pcm_2")
    assert Floki.text(second) =~ "<label>"
    assert Floki.find(doc, "[data-qa='plan_comment_missing']") == []
  end

  test "a row whose element is gone reads No longer found and can still be removed", %{comments: comments} do
    html =
      render_component(&PlanCommentTray.plan_comment_tray/1,
        comments: comments,
        missing: ["pcm_2"],
        can_send: true,
        plan_running: false,
        target: nil
      )

    [gone] = html |> Floki.parse_fragment!() |> Floki.find("#plan-comment-pcm_2")
    assert Floki.attribute(gone, "data-found") == ["false"]
    assert Floki.text(gone) =~ "No longer found"
    assert Floki.find(gone, "[data-qa='remove_plan_comment']") != []
  end

  test "folded, only the heading with its count shows", %{comments: comments} do
    html =
      render_component(&PlanCommentTray.plan_comment_tray/1,
        comments: comments,
        open: false,
        can_send: true,
        plan_running: false,
        target: nil
      )

    doc = Floki.parse_fragment!(html)
    assert doc |> Floki.find("#plan-comment-tray-count") |> Floki.text() == "2"
    assert Floki.find(doc, "[data-qa='plan_comment_row']") == []
    assert doc |> Floki.find("#plan-comment-tray-fold") |> Floki.attribute("aria-expanded") == ["false"]
  end

  test "Send shows the count and whether Plan is working only when it can send", %{comments: comments} do
    idle =
      render_component(&PlanCommentTray.plan_comment_tray/1,
        comments: comments,
        can_send: true,
        plan_running: false,
        target: nil
      )

    assert idle |> Floki.parse_fragment!() |> Floki.find("#send-plan-comments") |> Floki.text() =~ ~r/Send 2\s*comments/
    assert idle =~ "Plan is idle and starts on these at once."

    working =
      render_component(&PlanCommentTray.plan_comment_tray/1,
        comments: Enum.take(comments, 1),
        can_send: true,
        plan_running: true,
        target: nil
      )

    assert working |> Floki.parse_fragment!() |> Floki.find("#send-plan-comments") |> Floki.text() =~ ~r/Send 1\s*comment/
    assert working =~ "Plan is working. These wait until its turn ends."

    closed =
      render_component(&PlanCommentTray.plan_comment_tray/1,
        comments: comments,
        can_send: false,
        plan_running: false,
        target: nil
      )

    refute closed =~ "send-plan-comments"
    refute closed =~ "Plan is idle"
    assert closed =~ "Remove"
  end

  test "with nothing unsent there is no tray" do
    assert render_component(&PlanCommentTray.plan_comment_tray/1,
             comments: [],
             can_send: true,
             plan_running: false,
             target: nil
           ) == ""
  end

  test "ticket and plan rows name their document and line, and a changed one is dashed and says so" do
    comments = [
      %PlanComment{
        id: "pcm_t",
        target: :ticket,
        element_kind: :list_item,
        element_label: "Criterion 2",
        element_text: "A page that never goes idle starts after 10 seconds.",
        body: "Make it 5."
      },
      %PlanComment{
        id: "pcm_p",
        target: :plan,
        element_kind: :code,
        element_label: "Code line 2",
        element_text: "settle_cap_ms: 10_000,",
        body: "5_000."
      }
    ]

    html =
      render_component(&PlanCommentTray.plan_comment_tray/1,
        comments: comments,
        changed: ["pcm_p"],
        can_send: true,
        plan_running: false,
        target: nil
      )

    doc = Floki.parse_fragment!(html)

    [ticket] = Floki.find(doc, "#plan-comment-pcm_t")
    assert Floki.text(ticket) =~ ~r/Ticket\s+Criterion 2\s+"A page that never goes idle/
    assert Floki.attribute(ticket, "data-found") == ["true"]
    assert Floki.find(ticket, "[data-qa='plan_comment_changed']") == []

    [plan] = Floki.find(doc, "#plan-comment-pcm_p")
    assert Floki.text(plan) =~ ~r/Plan\s+Code line 2\s+"settle_cap_ms: 10_000,"/
    assert Floki.attribute(plan, "data-found") == ["false"]
    assert Floki.text(Floki.find(plan, "[data-qa='plan_comment_changed']")) =~ "Changed"
    assert [number | _icons] = Floki.attribute(plan, "span[aria-hidden='true']", "class")
    assert number =~ "border-dashed"
  end

  test "after approval, with Plan finished, the hint says sending resumes it and Engineer gets what it saves", %{
    comments: comments
  } do
    html =
      render_component(&PlanCommentTray.plan_comment_tray/1,
        comments: comments,
        can_send: true,
        plan_running: false,
        past_plan: true,
        target: nil
      )

    assert html |> Floki.parse_fragment!() |> Floki.find("#plan-comment-tray-hint") |> Floki.text() =~
             "Plan has finished. Sending resumes it, and Engineer gets what it saves."
  end
end
