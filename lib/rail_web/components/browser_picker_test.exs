defmodule RailWeb.Components.BrowserPickerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.BrowserPicker

  test "an idle browser with no account says it is idle and names nobody" do
    doc =
      (&BrowserPicker.browser_picker/1)
      |> render_component(
        sessions: [%{name: "explorer-1", account: nil, state: :idle}],
        picked: "explorer-1",
        interactive: true,
        target: nil
      )
      |> Floki.parse_fragment!()

    assert ["idle", "Click", "and", "type", "to", "use", "it"] =
             doc |> Floki.find("[data-qa=review_browser_line]") |> Floki.text(sep: " ") |> String.split()

    assert [{"span", [{"class", "shrink-0 text-slate-500 dark:text-slate-400"}], _text}] =
             Floki.find(doc, "[data-qa=review_browser_line] span.shrink-0")
  end

  test "a recording that has said one beat says so in the singular" do
    doc =
      (&BrowserPicker.browser_picker/1)
      |> render_component(
        sessions: [%{name: "demo", account: "dana@example.com", state: :recording}],
        picked: "demo",
        beats: 1,
        target: nil
      )
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("[data-qa=review_browser_line]") |> Floki.text() =~
             "Recording · 1 beat said so far · signed in as dana@example.com"
  end

  test "a browser a run drives is watch only, its frame marked so for the hook and closed to the pointer" do
    doc =
      (&BrowserPicker.browser_picker/1)
      |> render_component(
        sessions: [%{name: "explorer-1", account: "qa-1@rail.test", state: :driving}],
        picked: "explorer-1",
        target: nil
      )
      |> Floki.parse_fragment!()

    assert "Watch only while Review drives it · signed in as qa-1@rail.test" =
             doc |> Floki.find("#review-browser-mode") |> Floki.text() |> String.trim()

    assert ["false"] = doc |> Floki.find("#review-browser-frame") |> Floki.attribute("data-interactive")
    assert [] = doc |> Floki.find("#review-browser-frame") |> Floki.attribute("tabindex")
    assert [class] = doc |> Floki.find("#review-browser-frame") |> Floki.attribute("class")
    assert class =~ "cursor-not-allowed"
  end

  test "an interactive browser takes focus with a ring and says it can be used" do
    doc =
      (&BrowserPicker.browser_picker/1)
      |> render_component(
        sessions: [%{name: "explorer-1", account: "qa-1@rail.test", state: :idle}],
        picked: "explorer-1",
        interactive: true,
        target: nil
      )
      |> Floki.parse_fragment!()

    assert "Click and type to use it · signed in as qa-1@rail.test" =
             doc |> Floki.find("#review-browser-mode") |> Floki.text() |> String.trim()

    assert ["true"] = doc |> Floki.find("#review-browser-frame") |> Floki.attribute("data-interactive")
    assert ["0"] = doc |> Floki.find("#review-browser-frame") |> Floki.attribute("tabindex")
    assert [class] = doc |> Floki.find("#review-browser-frame") |> Floki.attribute("class")
    assert class =~ "focus:outline-blue-500"
    refute class =~ "cursor-not-allowed"
  end
end
