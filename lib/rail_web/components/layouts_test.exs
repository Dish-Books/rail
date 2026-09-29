defmodule RailWeb.LayoutsTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Users

  test "every page links an SVG favicon that turns dark with the browser", %{conn: conn} do
    html = conn |> get(~p"/sign-in") |> html_response(200)

    assert [href] =
             html |> Floki.parse_document!() |> Floki.attribute("link[rel='icon'][type='image/svg+xml']", "href")

    conn = get(conn, href)
    assert ["image/svg+xml"] = get_resp_header(conn, "content-type")

    assert [light, dark] = conn |> response(200) |> String.split("prefers-color-scheme: dark")
    assert light =~ "#dbeafe" and light =~ "#1e40af"
    assert dark =~ "#1e3a8a" and dark =~ "#bfdbfe"
  end

  # Chrome takes sizes="any" as the best match, and the ICO has no dark tile.
  test "the ICO fallback carries the tile at 16, 32 and 48 pixels and doesn't outrank the SVG", %{conn: conn} do
    html = conn |> get(~p"/sign-in") |> html_response(200)

    assert [{"link", attrs, _children}] = html |> Floki.parse_document!() |> Floki.find("link[rel='icon'][href$='.ico']")
    assert %{"href" => href, "sizes" => "32x32"} = Map.new(attrs)

    assert <<0, 0, 1, 0, 3, 0, 16, 16, _entry16::binary-size(14), 32, 32, _entry32::binary-size(14), 48, 48,
             _images::binary>> =
             conn |> get(href) |> response(200)
  end

  test "every page links a home screen icon", %{conn: conn} do
    html = conn |> get(~p"/sign-in") |> html_response(200)

    assert [href] = html |> Floki.parse_document!() |> Floki.attribute("link[rel='apple-touch-icon']", "href")

    assert <<137, "PNG", 13, 10, 26, 10, _length::32, "IHDR", 180::32, 180::32, _chunks::binary>> =
             conn |> get(href) |> response(200)
  end

  # Safari's 100vh counts its own toolbar, so a frame sized to it runs under the toolbar.
  test "the app frame is as tall as the visible viewport", %{conn: conn} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_layouts_frame",
        login: "layouts_frame_user",
        email: "layouts_frame_user@example.com"
      })

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/issues")

    assert [class] = view |> render() |> Floki.parse_fragment!() |> Floki.attribute("#app-scaffold", "class")
    assert "h-dvh" in String.split(class)
    refute "h-screen" in String.split(class)
  end
end
