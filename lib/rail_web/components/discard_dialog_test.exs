defmodule RailWeb.Components.DiscardDialogTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role
  alias RailWeb.Components.DiscardDialog

  setup do
    now = DateTime.utc_now()

    runs = [
      %Run{id: "run_lead", status: :running, role: %Role{name: "Review lead"}, started_at: now},
      %Run{
        id: "run_demo",
        status: :waiting_for_resources,
        role: %Role{name: "Demo recorder"},
        started_at: DateTime.shift(now, second: 1)
      },
      %Run{id: "run_code", status: :finished, role: %Role{name: "Code reviewer"}, started_at: now}
    ]

    task = %Task{
      worktree_name: "michael/rail-41-comments-left-on-diff-lines",
      pr_number: 212,
      pr_url: "https://github.com/org/rail/pull/212",
      issue: %Issue{identifier: "RAIL-41", state: :in_review, state_name: "In Review"},
      runs: runs
    }

    %{task: task}
  end

  test "lists each run in progress with its state, names the pull request, and says where the ticket goes", %{
    task: task
  } do
    doc = Floki.parse_fragment!(render_component(&DiscardDialog.discard_dialog/1, task: task))

    assert "Discard RAIL-41 and start over?" = doc |> Floki.find("#discard-title") |> Floki.text() |> String.trim()
    assert doc |> Floki.find("#discard-runs p") |> Floki.text() =~ "Stops 2 runs in progress"

    assert ["Review lead Running", "Demo recorder Waiting for resources"] =
             doc
             |> Floki.find("[data-qa=discard_run]")
             |> Enum.map(&(&1 |> Floki.text() |> String.split() |> Enum.join(" ")))

    assert doc |> Floki.find("#discard-pull-request a[href='https://github.com/org/rail/pull/212']") |> Floki.text() =~
             "PR #212"

    assert doc |> Floki.find("#discard-ticket") |> Floki.text() =~ "Moves RAIL-41 back to not started"
    assert doc |> Floki.find("#discard-ticket") |> Floki.text() =~ "In Review"
    assert "Discard" = doc |> Floki.find("#confirm-discard") |> Floki.text() |> String.trim()
  end

  test "a canceled ticket keeps its status, and nothing running says so", %{task: task} do
    task = %{task | issue: %Issue{identifier: "RAIL-38", state: :canceled}, runs: [], pr_number: nil}
    doc = Floki.parse_fragment!(render_component(&DiscardDialog.discard_dialog/1, task: task))

    assert doc |> Floki.find("#discard-runs") |> Floki.text() =~ "No runs in progress"
    assert [] = Floki.find(doc, "#discard-pull-request")
    assert doc |> Floki.find("#discard-ticket") |> Floki.text() =~ "Leaves RAIL-38 at Canceled"
    assert doc |> Floki.find("#discard-ticket") |> Floki.text() =~ "The ticket is already finished, so its status stays."
  end

  test "a pull request with no address is named without a link", %{task: task} do
    doc = Floki.parse_fragment!(render_component(&DiscardDialog.discard_dialog/1, task: %{task | pr_url: nil}))

    assert [] = Floki.find(doc, "#discard-pull-request a")
    assert doc |> Floki.find("#discard-pull-request") |> Floki.text() =~ "PR #212"
  end

  test "while discarding both buttons are disabled, and after an error the stopped runs and Discard again show", %{
    task: task
  } do
    doc = Floki.parse_fragment!(render_component(&DiscardDialog.discard_dialog/1, task: task, discarding: true))
    assert "Discarding…" = doc |> Floki.find("#confirm-discard[disabled]") |> Floki.text() |> String.trim()
    assert [_cancel] = Floki.find(doc, "#cancel-discard[disabled]")

    stopped = %{task | runs: Enum.map(task.runs, &%{&1 | status: :finished})}

    html = render_component(&DiscardDialog.discard_dialog/1, task: stopped, error: "GitHub refused to delete the branch.")
    doc = Floki.parse_fragment!(html)

    assert doc |> Floki.find("#discard-runs") |> Floki.text() =~ "Runs stopped"
    assert doc |> Floki.find("#discard-error[role=alert]") |> Floki.text() =~ "GitHub refused to delete the branch."
    assert "Discard again" = doc |> Floki.find("#confirm-discard") |> Floki.text() |> String.trim()
  end
end
