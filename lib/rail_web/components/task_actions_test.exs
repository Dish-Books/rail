defmodule RailWeb.Components.TaskActionsTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Domain.Embeds.DesignDirection
  alias Rail.Pipeline.Schemas.Task
  alias RailWeb.Components.TaskActionModals
  alias RailWeb.Components.TaskActions

  test "renders only trailing common actions for a merged task" do
    html =
      render_component(&TaskActions.task_actions/1,
        task: %Task{
          stage: :merged,
          stage_state: :awaiting_approval,
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
        task: %Task{
          stage: :ready_to_merge,
          stage_state: :awaiting_approval,
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
        task: %Task{
          stage: :ready_to_merge,
          stage_state: :awaiting_approval,
          pr_number: 42,
          pr_is_draft: true,
          mergeability: :conflicts
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
        task: %Task{
          stage: :ready_to_merge,
          stage_state: :awaiting_approval,
          pr_number: 42,
          pr_is_draft: false,
          mergeability: :conflicts
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
        task: %Task{
          stage: :ready_to_merge,
          stage_state: :awaiting_approval,
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
        task: %Task{
          stage: :design,
          stage_state: :awaiting_approval,
          designs: [design]
        },
        design: design
      )

    assert html =~ "Use Minimalist"
    assert html =~ "action-pick-design-dir_a"
    assert html =~ "Use Compact"
    assert html =~ "action-pick-design-dir_b"
    assert html =~ "Send back with comments"
    refute html =~ "action-approve"
  end

  test "renders Send back to Engineer and Skip at gate stages with strictly NO approve" do
    for gate_stage <- [:review, :qa, :qa_lead] do
      html =
        render_component(&TaskActions.task_actions/1,
          task: %Task{
            stage: gate_stage,
            stage_state: :awaiting_approval
          }
        )

      assert html =~ "Send back to Engineer"
      assert html =~ "action-send-back-to-engineer"
      assert html =~ "Skip"
      assert html =~ "action-skip"
      assert html =~ "Send back with comments"
      assert html =~ "action-send-back"
      refute html =~ "action-approve"
    end
  end

  test "renders standard approve and approve-skip-design at product stage" do
    html =
      render_component(&TaskActions.task_actions/1,
        task: %Task{
          stage: :product,
          stage_state: :awaiting_approval
        }
      )

    assert html =~ "Approve"
    assert html =~ "action-approve"
    assert html =~ "Approve, skip design"
    assert html =~ "action-approve-skip-design"
    assert html =~ "Send back with comments"
  end

  test "renders Send to review at engineer stage" do
    html =
      render_component(&TaskActions.task_actions/1,
        task: %Task{
          stage: :engineer,
          stage_state: :awaiting_approval
        }
      )

    assert html =~ "Send to review"
    assert html =~ "action-send-to-review"
    refute html =~ "Approve, skip design"
    assert html =~ "Send back with comments"
  end

  test "renders failed demo stage with Re-record and Continue without demo" do
    html =
      render_component(&TaskActions.task_actions/1,
        task: %Task{
          stage: :demo,
          stage_state: :failed
        }
      )

    assert html =~ "Re-record demo"
    assert html =~ "action-rerecord-demo"
    assert html =~ "Continue without a demo"
    assert html =~ "action-decline-demo"
    assert html =~ "Send back with comments"
  end

  test "renders failed design stage with Design is done and Re-run designer (no Retry)" do
    html =
      render_component(&TaskActions.task_actions/1,
        task: %Task{
          stage: :design,
          stage_state: :failed
        }
      )

    assert html =~ "Design is done"
    assert html =~ "action-recheck-design"
    assert html =~ "Re-run designer"
    assert html =~ "action-retry"
    refute html =~ ">Retry<"
    assert html =~ "Send back with comments"
  end

  test "renders failed other stage with Retry" do
    html =
      render_component(&TaskActions.task_actions/1,
        task: %Task{
          stage: :engineer,
          stage_state: :failed
        }
      )

    assert html =~ ">Retry<"
    assert html =~ "action-retry"
    assert html =~ "Send back with comments"
  end

  test "renders Cancel run when running, stays enabled, while cleanup is disabled" do
    html =
      render_component(&TaskActions.task_actions/1,
        task: %Task{
          stage: :engineer,
          stage_state: :running
        }
      )

    assert html =~ "Cancel run"
    assert html =~ "action-cancel"
    refute html =~ ~s(id="action-cancel" data-qa="action-cancel" disabled)

    # Clean up is disabled while running
    assert html =~ ~s(id="action-cleanup" data-qa="action-cleanup" disabled)
    # Chat is kind nil and stays enabled
    refute html =~ ~s(id="action-chat" data-qa="action-chat" disabled)
  end

  test "renders queued stage with no run control: dispatch is gone" do
    html =
      render_component(&TaskActions.task_actions/1,
        task: %Task{
          stage: :engineer,
          stage_state: :queued,
          retry_after: nil
        }
      )

    refute html =~ "action-dispatch"
    assert html =~ "action-send-back"
  end

  test "renders Unblock when blocked and question_id is nil" do
    html =
      render_component(&TaskActions.task_actions/1,
        task: %Task{
          stage: :architect,
          stage_state: :blocked,
          question_id: nil
        }
      )

    assert html =~ "Unblock"
    assert html =~ "action-unblock"
    refute html =~ ~s(id="action-unblock" data-qa="action-unblock" disabled)
  end

  test "does not render Unblock when question_id is present" do
    html =
      render_component(&TaskActions.task_actions/1,
        task: %Task{
          stage: :architect,
          stage_state: :blocked,
          question_id: "qst_123"
        }
      )

    refute html =~ "Unblock"
  end

  test "renders progress spinner when action is running and shows progress" do
    html =
      render_component(&TaskActions.task_actions/1,
        task: %Task{
          stage: :ready_to_merge,
          stage_state: :awaiting_approval,
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

  test "renders prompt_send_back modal with role name" do
    task = %Task{id: "tsk_1"}

    html =
      render_component(&TaskActionModals.task_action_modals/1,
        task: task,
        active_modal: %{type: :prompt_send_back, role_name: "Engineer"}
      )

    assert html =~ "Comment to Engineer"
    assert html =~ "What should change?"
    assert html =~ "Send back"
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
        task: %Task{stage: :engineer, stage_state: :unknown_state, worktree_path: "/tmp/w"}
      )

    refute html =~ "action-approve"
    assert html =~ "action-chat"
  end

  test "resolves design directions and picked key from task.designs fallback" do
    task = %Task{
      stage: :design,
      stage_state: :awaiting_approval,
      designs: [
        %Design{
          version: 1,
          picked_key: "dir_a",
          directions: [%DesignDirection{key: "dir_a", title: "Direction A"}]
        }
      ]
    }

    html = render_component(&TaskActions.task_actions/1, task: task, design: nil)
    assert html =~ "action-approve"
    assert html =~ "action-send-back"
  end

  test "resolves design directions and unpicked key from task.designs fallback" do
    task = %Task{
      stage: :design,
      stage_state: :awaiting_approval,
      designs: [
        %Design{
          version: 1,
          picked_key: nil,
          directions: [%DesignDirection{key: "dir_b", title: "Direction B"}]
        }
      ]
    }

    html = render_component(&TaskActions.task_actions/1, task: task, design: nil)
    assert html =~ "action-pick-design-dir_b"
  end

  test "handles design with no directions or picked key gracefully" do
    task = %Task{
      stage: :design,
      stage_state: :awaiting_approval,
      designs: []
    }

    html = render_component(&TaskActions.task_actions/1, task: task, design: nil)
    refute html =~ "action-pick-design"
  end
end
