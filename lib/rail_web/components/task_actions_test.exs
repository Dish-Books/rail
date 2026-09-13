defmodule RailWeb.Components.TaskActionsTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Domain.Embeds.DesignDirection
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.Run
  alias RailWeb.Components.TaskActionModals
  alias RailWeb.Components.TaskActions

  test "renders only trailing common actions for a merged task" do
    html =
      render_component(&TaskActions.task_actions/1,
        run: %Run{status: :finished, stage_outcome: :done},
        task: %Task{
          stage: :merged,
          worktree_path: "/tmp/worktree"
        }
      )

    assert html =~ "action-chat"
    assert html =~ "action-view-diff"
    assert html =~ "action-cleanup"
    refute html =~ "action-approve"
    refute html =~ "action-send-back"
    refute html =~ "action-merge"
  end

  test "renders ready_to_merge actions for clean, draft PR" do
    html =
      render_component(&TaskActions.task_actions/1,
        run: %Run{status: :finished, stage_outcome: :done},
        task: %Task{
          stage: :ready_to_merge,
          pr_number: 42,
          pr_is_draft: true,
          mergeability: :clean
        }
      )

    assert html =~ "Mark ready for review"
    assert html =~ "action-mark-ready"
    assert html =~ "Send back to Engineer"
    assert html =~ "action-send-back-to-engineer"
    # Draft cannot be merged
    refute html =~ "action-merge"
    # Absent at ready_to_merge
    refute html =~ ~s(id="action-send-back")
  end

  test "renders ready_to_merge actions for conflicted, draft PR" do
    html =
      render_component(&TaskActions.task_actions/1,
        run: %Run{status: :finished, stage_outcome: :done},
        task: %Task{
          stage: :ready_to_merge,
          pr_number: 42,
          pr_is_draft: true,
          mergeability: :conflicting
        }
      )

    assert html =~ "Rebase branch"
    assert html =~ "action-rebase"
    assert html =~ "Mark ready for review"
    assert html =~ "action-mark-ready"
    assert html =~ "Send back to Engineer"
    assert html =~ "action-send-back-to-engineer"
    refute html =~ "action-merge"
  end

  test "renders ready_to_merge actions for conflicted, non-draft PR" do
    html =
      render_component(&TaskActions.task_actions/1,
        run: %Run{status: :finished, stage_outcome: :done},
        task: %Task{
          stage: :ready_to_merge,
          pr_number: 42,
          pr_is_draft: false,
          mergeability: :conflicting
        }
      )

    assert html =~ "Rebase branch"
    assert html =~ "action-rebase"
    assert html =~ "Merge anyway"
    assert html =~ "action-merge-anyway"
    assert html =~ "Send back to Engineer"
    assert html =~ "action-send-back-to-engineer"
    refute html =~ "Merge pull request"
  end

  test "renders ready_to_merge actions for clean, non-draft PR" do
    html =
      render_component(&TaskActions.task_actions/1,
        run: %Run{status: :finished, stage_outcome: :done},
        task: %Task{
          stage: :ready_to_merge,
          pr_number: 42,
          pr_is_draft: false,
          mergeability: :clean
        }
      )

    assert html =~ "Merge pull request"
    assert html =~ "action-merge"
    assert html =~ "Send back to Engineer"
    assert html =~ "action-send-back-to-engineer"
    refute html =~ "Merge anyway"
    refute html =~ "action-rebase"
  end

  test "renders direction buttons and no generic approve at design stage when unpicked" do
    design = %Design{
      picked_key: nil,
      directions: [
        %DesignDirection{key: "dir_a", title: "Minimalist"},
        %DesignDirection{key: "dir_b", title: "Compact"}
      ]
    }

    html =
      render_component(&TaskActions.task_actions/1,
        run: %Run{status: :finished, stage_outcome: :done},
        task: %Task{stage: :design},
        design: design,
        design: design
      )

    assert html =~ "Use Minimalist"
    assert html =~ "action-pick-design-dir_a"
    assert html =~ "Use Compact"
    assert html =~ "action-pick-design-dir_b"
    refute html =~ "action-approve"
  end

  test "renders Send back to Engineer and Skip at gate stages with strictly NO approve" do
    for gate_stage <- [:review, :qa, :qa_lead] do
      html =
        render_component(&TaskActions.task_actions/1,
          run: %Run{status: :finished, stage_outcome: :done},
          task: %Task{
            stage: gate_stage
          }
        )

      assert html =~ "Send back to Engineer"
      assert html =~ "action-send-back-to-engineer"
      assert html =~ "Skip"
      assert html =~ "action-skip"
      refute html =~ "action-approve"
    end
  end

  test "offers no stage actions at product stage, since approving is stage-specific" do
    html =
      render_component(&TaskActions.task_actions/1,
        run: %Run{status: :finished, stage_outcome: :done},
        task: %Task{
          stage: :product
        }
      )

    refute html =~ "action-approve"
    refute html =~ "Approve, skip design"
    assert html =~ "action-chat"
  end

  test "offers no stage actions at engineer stage, since approving is stage-specific" do
    html =
      render_component(&TaskActions.task_actions/1,
        run: %Run{status: :finished, stage_outcome: :done},
        task: %Task{
          stage: :engineer
        }
      )

    refute html =~ "action-send-to-review"
    refute html =~ "Approve, skip design"
    assert html =~ "action-chat"
  end

  test "renders failed demo stage with Re-record and Continue without demo" do
    html =
      render_component(&TaskActions.task_actions/1,
        run: %Run{status: :finished, error: "boom"},
        task: %Task{
          stage: :demo
        }
      )

    assert html =~ "Re-record demo"
    assert html =~ "action-rerecord-demo"
    assert html =~ "Continue without a demo"
    assert html =~ "action-decline-demo"
  end

  test "renders failed design stage with Design is done and Re-run designer (no Retry)" do
    html =
      render_component(&TaskActions.task_actions/1,
        run: %Run{status: :finished, error: "boom"},
        task: %Task{
          stage: :design
        }
      )

    assert html =~ "Design is done"
    assert html =~ "action-recheck-design"
    assert html =~ "Re-run designer"
    assert html =~ "action-retry"
    refute html =~ ">Retry<"
  end

  test "renders failed other stage with Retry" do
    html =
      render_component(&TaskActions.task_actions/1,
        run: %Run{status: :finished, error: "boom"},
        task: %Task{
          stage: :engineer
        }
      )

    assert html =~ ">Retry<"
    assert html =~ "action-retry"
  end

  test "offers no stage actions while the run is working, and disables clean up" do
    html =
      render_component(&TaskActions.task_actions/1,
        run: %Run{status: :running},
        task: %Task{
          stage: :engineer
        }
      )

    # Stopping lives in the conversation, not here.
    refute html =~ "action-cancel"

    assert html =~ ~s(id="action-cleanup" data-qa="action-cleanup" disabled)
    refute html =~ ~s(id="action-chat" data-qa="action-chat" disabled)
  end

  test "renders queued stage with no run control: dispatch is gone" do
    html =
      render_component(&TaskActions.task_actions/1,
        task: %Task{
          stage: :engineer
        }
      )

    refute html =~ "action-dispatch"
    refute html =~ "action-send-back"
  end

  test "offers no stage actions while blocked, only the trailing common ones" do
    html =
      render_component(&TaskActions.task_actions/1,
        run: %Run{status: :blocked_on_input},
        task: %Task{
          stage: :architect
        }
      )

    refute html =~ "Unblock"
    refute html =~ "action-send-back"
    assert html =~ "action-chat"
    assert html =~ "action-cleanup"
  end

  test "renders progress spinner when action is running and shows progress" do
    html =
      render_component(&TaskActions.task_actions/1,
        run: %Run{status: :finished, stage_outcome: :done},
        task: %Task{
          stage: :ready_to_merge,
          pr_number: 55,
          mergeability: :clean
        },
        running_action: :merge
      )

    assert html =~ "data-qa=\"action-spinner\""
    assert html =~ "Merge pull request"
    assert html =~ ~s(id="action-send-back-to-engineer" data-qa="action-send-back-to-engineer" disabled)
    refute html =~ ~s(id="action-chat" data-qa="action-chat" disabled)
  end

  test "renders confirm_merge modal with and without ignore_conflicts" do
    task = %Task{id: "tsk_1", pr_number: 101}

    # Clean merge
    html_clean =
      render_component(&TaskActionModals.task_action_modals/1,
        task: task,
        active_modal: %{type: :confirm_merge, ignore_conflicts: false}
      )

    assert html_clean =~ "Merge this pull request?"
    assert html_clean =~ "Squash-merges PR #101"
    refute html_clean =~ "GitHub last reported conflicts"

    # Conflicted merge
    html_conflicts =
      render_component(&TaskActionModals.task_action_modals/1,
        task: task,
        active_modal: %{type: :confirm_merge, ignore_conflicts: true}
      )

    assert html_conflicts =~ "GitHub last reported conflicts on this pull request."
  end

  test "renders confirm_rebase modal with engineer role and stage label" do
    task = %Task{id: "tsk_1", pr_number: 102, stage: :ready_to_merge}

    html =
      render_component(&TaskActionModals.task_action_modals/1,
        task: task,
        active_modal: %{type: :confirm_rebase}
      )

    assert html =~ "Rebase this branch?"
    assert html =~ "The engineer rebases the branch onto main"
    assert html =~ "PR #102"
    assert html =~ "Ready to merge"
  end

  test "renders confirm_cleanup modal" do
    task = %Task{id: "tsk_1"}

    html =
      render_component(&TaskActionModals.task_action_modals/1,
        task: task,
        active_modal: %{type: :confirm_cleanup}
      )

    assert html =~ "Clean up this task?"
    assert html =~ "Removes the worktree and its branch"
    assert html =~ "Clean up"
  end

  test "renders prompt_send_back_to_engineer modal with subtitle" do
    task = %Task{id: "tsk_1"}

    html =
      render_component(&TaskActionModals.task_action_modals/1,
        task: task,
        active_modal: %{type: :prompt_send_back_to_engineer}
      )

    assert html =~ "Send back to Engineer"
    assert html =~ "The findings already on this change go back with it"
    assert html =~ "Optional - anything else it should do?"
  end

  test "renders prompt_decline_demo modal with subtitle" do
    task = %Task{id: "tsk_1"}

    html =
      render_component(&TaskActionModals.task_action_modals/1,
        task: task,
        active_modal: %{type: :prompt_decline_demo}
      )

    assert html =~ "Continue without a demo"
    assert html =~ "A demo will not be recorded for this task"
    assert html =~ "Continue"
  end

  test "renders empty when task is nil" do
    html = render_component(&TaskActions.task_actions/1, task: nil)
    assert html =~ "flex"
    refute html =~ "button"
  end

  test "handles unhandled stage_state gracefully" do
    html =
      render_component(&TaskActions.task_actions/1,
        task: %Task{stage: :engineer, worktree_path: "/tmp/w"}
      )

    refute html =~ "action-approve"
    assert html =~ "action-chat"
  end

  test "offers nothing to pick when no design was handed in" do
    task = %Task{stage: :design}

    html =
      render_component(&TaskActions.task_actions/1,
        task: task,
        run: %Run{status: :finished, stage_outcome: :done},
        design: nil
      )

    refute html =~ "action-pick-design-dir_a"
    assert html =~ "action-chat"
  end

  test "offers each direction of the design it was handed" do
    task = %Task{stage: :design}

    html =
      render_component(&TaskActions.task_actions/1,
        task: task,
        run: %Run{status: :finished, stage_outcome: :done},
        design: %Design{
          version: 1,
          picked_key: nil,
          directions: [%DesignDirection{key: "dir_b", title: "Direction B"}]
        }
      )

    assert html =~ "action-pick-design-dir_b"
  end

  test "handles a design with no directions gracefully" do
    html =
      render_component(&TaskActions.task_actions/1,
        task: %Task{stage: :design},
        run: %Run{status: :finished, stage_outcome: :done},
        design: %Design{version: 1, picked_key: nil, directions: []}
      )

    refute html =~ "action-pick-design"
  end
end
