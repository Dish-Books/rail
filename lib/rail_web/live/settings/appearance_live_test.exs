defmodule RailWeb.Settings.AppearanceLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "redirects unauthenticated user to /auth/github", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/github"}}} = live(conn, ~p"/settings/appearance")
  end

  test "renders appearance settings and theme segments", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/appearance")
    assert has_element?(view, "#appearance-settings")
    assert has_element?(view, "#appearance-title", "Appearance")
    assert has_element?(view, "#theme-segmented-button")
    assert has_element?(view, "#theme-segment-system")
    assert has_element?(view, "#theme-segment-light")
    assert has_element?(view, "#theme-segment-dark")
  end

  test "switches theme on clicking segment button", %{conn: conn} do
    {authed_conn, _user} = log_in_test_user(conn)

    assert {:ok, view, _html} = live(authed_conn, ~p"/settings/appearance")

    view |> element("#theme-segment-light") |> render_click()
    assert has_element?(view, "#theme-segment-light.bg-white")

    view |> element("#theme-segment-system") |> render_click()
    assert has_element?(view, "#theme-segment-system.bg-white")

    view |> element("#theme-segment-dark") |> render_click()
    assert has_element?(view, "#theme-segment-dark.bg-white")
  end
end
