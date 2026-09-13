defmodule RailWeb.Components.NoDemoBannerTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.Run
  alias RailWeb.Components.NoDemoBanner

  setup do
    File.mkdir_p!("/tmp/worktree")
    :ok
  end

  test "renders no-demo banner with record demo button when eligible" do
    task = %Task{
      id: "tsk_demo_elig",
      stage: :ready_to_merge,
      worktree_path: "/tmp/worktree"
    }

    html =
      render_component(&NoDemoBanner.no_demo_banner/1, task: task, run: %Run{status: :finished, stage_outcome: :done})

    assert html =~ "id=\"no-demo-banner\""
    assert html =~ "id=\"no-demo-title\""
    assert html =~ "No demo recorded"
    assert html =~ "id=\"no-demo-body\""
    assert html =~ "This task reached Ready to merge without recording a demo (gates were skipped)."
    assert html =~ "id=\"action-record-demo\""
    assert html =~ "phx-click=\"rerecord_demo\""
    assert html =~ "Record demo"
  end

  test "hides record demo button when task is not eligible to re-record" do
    # Merged task
    merged_task = %Task{
      id: "tsk_merged",
      stage: :merged,
      merged_at: DateTime.utc_now(),
      worktree_path: "/tmp/worktree"
    }

    html =
      render_component(&NoDemoBanner.no_demo_banner/1,
        task: merged_task,
        run: %Run{status: :finished, stage_outcome: :done}
      )

    assert html =~ "id=\"no-demo-banner\""
    refute html =~ "id=\"action-record-demo\""

    # Worktree removed from disk
    no_worktree_task = %Task{
      id: "tsk_no_wt",
      stage: :ready_to_merge,
      worktree_path: "/tmp/rail-removed-worktree"
    }

    html_no_wt =
      render_component(&NoDemoBanner.no_demo_banner/1,
        task: no_worktree_task,
        run: %Run{status: :finished, stage_outcome: :done}
      )

    refute html_no_wt =~ "id=\"action-record-demo\""

    # Plain map task that is not eligible: already merged
    plain_map_task = %{
      id: "tsk_plain",
      stage: :merged,
      worktree_path: "/tmp/worktree"
    }

    html_plain =
      render_component(&NoDemoBanner.no_demo_banner/1,
        task: plain_map_task,
        run: %Run{status: :finished, stage_outcome: :done}
      )

    refute html_plain =~ "id=\"action-record-demo\""

    # nil task
    html_nil =
      render_component(&NoDemoBanner.no_demo_banner/1, task: nil, run: %Run{status: :finished, stage_outcome: :done})

    assert html_nil =~ "id=\"no-demo-banner\""
    refute html_nil =~ "id=\"action-record-demo\""
  end
end
