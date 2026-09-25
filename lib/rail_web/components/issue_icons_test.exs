defmodule RailWeb.Components.IssueIconsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.IssueIcons

  test "a status icon is drawn for every state an issue can be in" do
    assert render_component(&IssueIcons.status_icon/1, state: :in_review) =~ "pi-circle-half-tilt-fill"
    assert render_component(&IssueIcons.status_icon/1, state: :canceled) =~ "pi-x-circle-fill"
    assert render_component(&IssueIcons.status_icon/1, state: :duplicate) =~ "pi-x-circle-fill"
  end

  test "an assignee with an avatar is shown as it" do
    html =
      render_component(&IssueIcons.assignee/1,
        user: %{avatar_url: "https://example.com/paulo.png", name: nil, login: "paulo"}
      )

    assert html =~ ~s(src="https://example.com/paulo.png")
    assert html =~ ~s(alt="paulo")
  end
end
