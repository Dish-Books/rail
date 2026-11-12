defmodule RailWeb.Components.MoveToRailDialogTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects.Schemas.Project
  alias RailWeb.Components.MoveToRailDialog

  setup do
    %{project: %Project{id: "prj_move_dialog", name: "Rail", key: "RAIL"}}
  end

  test "says what comes across and what stays, that it can't be undone, and offers Cancel and Move to Rail", %{
    project: project
  } do
    doc = Floki.parse_fragment!(render_component(&MoveToRailDialog.move_to_rail_dialog/1, project: project))

    assert "Move Rail off Linear?" = doc |> Floki.find("#move-title") |> Floki.text() |> String.trim()

    assert doc |> Floki.find("#move-dialog") |> Floki.text() =~
             "Rail copies every RAIL ticket from Linear, archived ones included, with its comments, cycles, blockers, links and files"

    assert [
             "Identifiers, branches and tasks stay as they are.",
             "Linear stops changing these tickets, and Rail stops writing to Linear.",
             "It can't be undone."
           ] = doc |> Floki.find("#move-dialog li") |> Enum.map(&(&1 |> Floki.text() |> String.trim()))

    assert "Cancel" = doc |> Floki.find("#cancel-move") |> Floki.text() |> String.trim()

    assert [{"button", attrs, _children}] = Floki.find(doc, "#confirm-move")
    assert {"phx-value-project_id", "prj_move_dialog"} in attrs
    assert [] = Floki.find(doc, "#move-error")
  end

  test "Escape, Close and Cancel each close it and hand focus back to the row's button", %{project: project} do
    doc = Floki.parse_fragment!(render_component(&MoveToRailDialog.move_to_rail_dialog/1, project: project))

    assert ["Escape"] = Floki.attribute(doc, "#move-dialog-backdrop", "phx-key")

    for {selector, attribute} <- [
          {"#move-dialog-backdrop", "phx-window-keydown"},
          {"#close-move-dialog", "phx-click"},
          {"#cancel-move", "phx-click"}
        ] do
      assert [command] = Floki.attribute(doc, selector, attribute)
      assert command =~ "close_move"
      assert command =~ "#move-project-prj_move_dialog"
    end
  end

  test "an error stays in the dialog", %{project: project} do
    doc =
      Floki.parse_fragment!(
        render_component(&MoveToRailDialog.move_to_rail_dialog/1,
          project: project,
          error: "Rail is no longer on Linear. Another tab already moved it."
        )
      )

    assert "Rail is no longer on Linear. Another tab already moved it." =
             doc |> Floki.find("#move-error[role=alert]") |> Floki.text() |> String.trim()
  end
end
