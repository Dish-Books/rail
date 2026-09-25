defmodule RailWeb.LayoutsTest do
  use RailWeb.ConnCase, async: true

  test "every page links a favicon the app serves", %{conn: conn} do
    html = conn |> get(~p"/sign-in") |> html_response(200)

    assert [href] = html |> Floki.parse_document!() |> Floki.attribute("link[rel='icon']", "href")
    # An ICO file opens with a reserved zero word and then type 1.
    assert <<0, 0, 1, 0, _rest::binary>> = conn |> get(href) |> response(200)
  end
end
