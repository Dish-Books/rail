defmodule RailWeb.LayoutsTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Users

  test "every page links a favicon the app serves", %{conn: conn} do
    html = conn |> get(~p"/sign-in") |> html_response(200)

    assert [href] = html |> Floki.parse_document!() |> Floki.attribute("link[rel='icon']", "href")
    # An ICO file opens with a reserved zero word and then type 1.
    assert <<0, 0, 1, 0, _rest::binary>> = conn |> get(href) |> response(200)
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
