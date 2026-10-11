defmodule RailWeb.Components.DesignOptionTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.Task
  alias RailWeb.Components.DesignOption

  setup_all do
    option = %{
      key: "table",
      title: "Table",
      summary: "Dense.",
      good_at: ["Fast"],
      costs: ["Busy at 1280px"],
      assumptions: "Ten per page.",
      html: "<h1>table</h1>",
      html_version: "v1"
    }

    %{task: %Task{id: "tsk_design_option"}, option: option}
  end

  test "with no comment state the frame takes no comments and there is nothing to comment or pick with", %{
    task: task,
    option: option
  } do
    html =
      (&DesignOption.design_option/1)
      |> render_component(id: "review-design-none", task: task, option: option, picked: true)
      |> Floki.parse_fragment!()

    assert Floki.text(Floki.find(html, "#design-option-table")) =~ "Picked"
    assert Floki.attribute(html, "#design-frame-table", "data-comments") == ["false"]
    assert Floki.attribute(html, "#design-frame-table", "data-task-id") == []
    assert [src] = Floki.attribute(html, "#design-frame-table iframe", "src")
    refute src =~ "comments=1"
    assert Floki.attribute(html, "#open-design-table", "href") == ["/tasks/tsk_design_option/design/table?v=v1"]
    assert Floki.text(Floki.find(html, "#design-good-at")) =~ "Fast"
    assert Floki.text(Floki.find(html, "#design-costs")) =~ "Busy at 1280px"
    assert Floki.text(Floki.find(html, "#design-assumptions")) =~ "Ten per page."
    assert Floki.find(html, "#design-comment-control") == []
    assert Floki.find(html, "[data-qa='pick_design']") == []
  end

  test "with comment state the frame loads the overlay and carries the mode and markers", %{task: task, option: option} do
    comments = %{commenting: true, draft: nil, markers: [%{id: "c1", number: 1, selector: "h1"}], user_id: "usr_1"}

    html =
      (&DesignOption.design_option/1)
      |> render_component(id: "plan-design-none", task: task, option: option, picked: true, comments: comments)
      |> Floki.parse_fragment!()

    assert Floki.attribute(html, "#design-frame-table", "data-comments") == ["true"]
    assert Floki.attribute(html, "#design-frame-table", "data-commenting") == ["true"]
    assert Floki.attribute(html, "#design-frame-table", "data-task-id") == ["tsk_design_option"]
    assert [src] = Floki.attribute(html, "#design-frame-table iframe", "src")
    assert src =~ "comments=1"
  end

  test "an option with no page yet says so, and an unpicked one has no Picked", %{task: task, option: option} do
    html =
      (&DesignOption.design_option/1)
      |> render_component(id: "plan-design-none", task: task, option: %{option | html: nil, html_version: nil})
      |> Floki.parse_fragment!()

    assert Floki.text(html) =~ "This option has no page yet."
    refute Floki.text(html) =~ "Picked"
    assert Floki.find(html, "#open-design-table") == []
  end

  test "with no option it reads No screen in this change, with the caller's note after it", %{task: task} do
    assigns = %{task: task}

    html =
      ~H"""
      <DesignOption.design_option id="plan-design-none" task={@task}>
        <:note>Approve needs only the ticket and the plan.</:note>
      </DesignOption.design_option>
      """
      |> rendered_to_string()
      |> Floki.parse_fragment!()

    assert Floki.attribute(html, "#plan-design-none", "data-qa") == ["plan_design_none"]
    assert Floki.text(html) =~ "No screen in this change"

    assert Floki.text(html) =~
             "Nothing anyone sees changes, so there are no design options. Approve needs only the ticket and the plan."
  end

  test "the control, box and pick slots appear in place", %{task: task, option: option} do
    assigns = %{task: task, option: option}

    html =
      ~H"""
      <DesignOption.design_option id="plan-design-none" task={@task} option={@option}>
        <:control><span id="slot-control">Comment</span></:control>
        <:box><span id="slot-box">Box</span></:box>
        <:pick><button id="slot-pick">Use this design</button></:pick>
      </DesignOption.design_option>
      """
      |> rendered_to_string()
      |> Floki.parse_fragment!()

    assert [_control] = Floki.find(html, "#design-option-table > div:first-child > #slot-control")
    assert [_box] = Floki.find(html, "#design-frame-table #slot-box")
    assert [_pick] = Floki.find(html, "#slot-pick + #open-design-table")
  end
end
