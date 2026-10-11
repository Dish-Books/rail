defmodule RailWeb.Components.ReviewItemsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.ReviewItems

  setup_all do
    item = fn key, label, icon, state ->
      %{key: key, label: label, icon: icon, picked_icon: "#{icon}-fill", state: state, badge: nil, dot: nil, mark: nil}
    end

    items = [
      %{item.(:findings, "Findings", "pi-list-checks", "4 to rule") | badge: 4},
      item.(:diff, "Diff", "pi-git-diff", "No commits yet"),
      item.(:screens, "Screens", "pi-images", "No screens yet"),
      item.(:demo, "Demo", "pi-video-camera", "None recorded"),
      item.(:browser, "Browser", "pi-browsers", "No browsers open")
    ]

    documents = [
      item.(:ticket, "Ticket", "pi-file-text", "8 criteria"),
      item.(:design, "Design", "pi-palette", "Picked: Table"),
      item.(:plan, "Plan", "pi-compass-tool", "Revised after approval")
    ]

    %{items: items, documents: documents}
  end

  test "the documents sit after a divider that follows Browser", %{items: items, documents: documents} do
    html =
      (&ReviewItems.review_items/1)
      |> render_component(items: items, documents: documents, picked: :findings, target: nil)
      |> Floki.parse_fragment!()

    assert ["findings", "diff", "screens", "demo", "browser", "separator", "ticket", "design", "plan"] =
             html
             |> Floki.find("#review-items > *")
             |> Enum.map(&hd(Floki.attribute(&1, "phx-value-item") ++ Floki.attribute(&1, "role")))
  end

  test "with no documents there is no divider", %{items: items} do
    html =
      (&ReviewItems.review_items/1)
      |> render_component(items: items, picked: :findings, target: nil)
      |> Floki.parse_fragment!()

    assert Floki.find(html, "[role='separator']") == []
  end

  test "a picked document is styled as a picked work item, with its filled icon", %{items: items, documents: documents} do
    html =
      (&ReviewItems.review_items/1)
      |> render_component(items: items, documents: documents, picked: :plan, target: nil)
      |> Floki.parse_fragment!()

    [plan_class] = Floki.attribute(html, "#review-item-plan", "class")
    [findings_class] = Floki.attribute(html, "#review-item-findings", "class")
    assert plan_class =~ "bg-blue-50 dark:bg-blue-950/40 ring-1 ring-blue-200"
    refute findings_class =~ "bg-blue-50"
    assert Floki.attribute(html, "#review-item-plan", "aria-current") == ["true"]
    assert [_icon] = Floki.find(html, "#review-item-plan .pi-compass-tool-fill")
  end

  test "each label is screen-reader text under 540px of main column and shows from there up, its title naming it and its state",
       %{items: items, documents: documents} do
    html =
      (&ReviewItems.review_items/1)
      |> render_component(items: items, documents: documents, picked: :findings, target: nil)
      |> Floki.parse_fragment!()

    for {key, label, state} <- [{"findings", "Findings", "4 to rule"}, {"ticket", "Ticket", "8 criteria"}] do
      button = Floki.find(html, "#review-item-#{key}")
      assert Floki.attribute(button, "title") == ["#{label}: #{state}"]

      shown = Floki.find(button, "span.hidden")
      assert Floki.text(shown) =~ label
      assert [shown_class] = Floki.attribute(shown, "class")
      assert shown_class =~ "@min-[540px]:block"

      assert [said] = Floki.find(button, "span.sr-only[class*='@min-[540px]:hidden']")
      assert Floki.text(said) == label
    end
  end
end
