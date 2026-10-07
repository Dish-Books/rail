defmodule RailWeb.Components.ElementPreviewTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.ElementPreview

  @reset "<style>html,body{margin:0;overflow:hidden}body>*:first-child{margin:0}</style>"

  test "renders one iframe with every sandbox restriction on, sized to the box and holding only the element" do
    capture = %{"html" => "<h2>Needs you <span>3</span></h2>", "width" => 180, "height" => 22}
    html = render_component(&ElementPreview.element_preview/1, id: "preview", capture: capture)
    doc = Floki.parse_fragment!(html)

    assert [frame] = Floki.find(doc, "iframe")
    assert Floki.attribute(frame, "sandbox") == [""]
    assert Floki.attribute(frame, "srcdoc") == [@reset <> "<h2>Needs you <span>3</span></h2>"]
    assert Floki.attribute(frame, "src") == []
    assert [fit] = Floki.find(doc, "[phx-hook='ElementPreview']")
    assert Floki.attribute(fit, "data-width") == ["180"]
    assert Floki.attribute(fit, "data-height") == ["22"]
    assert Floki.attribute(frame, "style") == ["width: 180px; height: 22px;"]
  end

  test "a capture holding a script, a button and a quote appears only inside the escaped srcdoc" do
    hostile = ~s{<div onclick="steal()"><script>alert("x")</script><button title='a"b'>Go</button></div>}

    html =
      render_component(&ElementPreview.element_preview/1,
        id: "preview",
        capture: %{"html" => hostile, "width" => 300, "height" => 40}
      )

    doc = Floki.parse_fragment!(html)

    assert Floki.find(doc, "script") == []
    assert Floki.find(doc, "button") == []
    assert Floki.find(doc, "[onclick]") == []
    assert doc |> Floki.find("iframe") |> Floki.attribute("srcdoc") == [@reset <> hostile]
    refute html =~ "<script>"
  end
end
