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
        target: nil
      )
      |> Floki.parse_fragment!()

    assert "idle Idle" = doc |> Floki.find("[data-qa=review_browser_line]") |> Floki.text(sep: " ") |> String.trim()

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
end
