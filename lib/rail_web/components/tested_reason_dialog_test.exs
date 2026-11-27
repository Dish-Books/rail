defmodule RailWeb.Components.TestedReasonDialogTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.TestedReasonDialog

  test "asks why the ticket had nothing to test, with a required box that submits the reason for the ticket" do
    html =
      (&TestedReasonDialog.tested_reason_dialog/1)
      |> render_component(issue_id: "iss_1", identifier: "DSH-212")
      |> Floki.parse_fragment!()

    assert html |> Floki.find("#tested-reason-title") |> Floki.text() |> String.trim() ==
             "Mark DSH-212 tested with no scenarios"

    assert Floki.attribute(html, "#tested-reason-dialog", "phx-submit") == ["mark_tested"]
    assert Floki.attribute(html, "#tested-reason-dialog input[name='issue_id']", "value") == ["iss_1"]
    assert Floki.attribute(html, "#tested-reason", "name") == ["no_scenarios_reason"]
    assert Floki.attribute(html, "#tested-reason", "required") == ["required"]
    assert Floki.attribute(html, "#tested-reason-backdrop", "phx-key") == ["Escape"]
    assert Floki.find(html, "#tested-reason-error") == []
  end

  test "a missing reason shows its message under the box" do
    html =
      (&TestedReasonDialog.tested_reason_dialog/1)
      |> render_component(issue_id: "iss_1", identifier: "DSH-212", error: "Write why there was nothing to test.")
      |> Floki.parse_fragment!()

    assert html |> Floki.find("#tested-reason-error") |> Floki.text() |> String.trim() ==
             "Write why there was nothing to test."

    assert Floki.attribute(html, "#tested-reason", "aria-describedby") == ["tested-reason-error"]
  end
end
