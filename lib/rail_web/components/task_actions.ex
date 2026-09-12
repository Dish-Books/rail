defmodule RailWeb.Components.TaskActions do
  @moduledoc """
  Task actions wrap component rendering the exact action button matrix
  for a task moving through the pipeline, including trailing common actions,
  enable/disable states, and progress spinners.
  """

  use RailWeb, :html

  import RailWeb.CoreComponents, only: [icon: 1]

  alias Rail.Domain.Formatters
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.TaskActionRunner

  attr :task, :any, required: true
  attr :pending_questions, :list, default: []
  attr :running_action, :atom, default: nil
  attr :design, :any, default: nil
  attr :on_action, :string, default: "action_click"
  attr :id, :string, default: "task-actions"
  attr :class, :string, default: nil

  def task_actions(assigns) do
    actions = build_actions(assigns.task, assigns.design, assigns.pending_questions)

    assigns = assign(assigns, :actions, actions)

    ~H"""
    <div
      id={@id}
      data-qa="task-actions"
      class={["flex flex-wrap items-center gap-2", @class]}
    >
      <%= for action <- @actions do %>
        <% is_disabled = action_disabled?(@task, action.kind, @running_action)

        show_spinner =
          @running_action == action.kind and TaskActionRunner.shows_progress?(action.kind)

        data_qa =
          cond do
            action.id == "action-send-back" ->
              "#{action.id} action-request-changes"

            String.starts_with?(action.id, "action-pick-design-") ->
              "#{action.id} pick-direction-button"

            true ->
              action.id
          end %>
        <button
          type="button"
          id={action.id}
          data-qa={data_qa}
          disabled={is_disabled}
          phx-click={@on_action}
          phx-value-action={action.action}
          phx-value-kind={action.kind}
          phx-value-direction_key={Map.get(action.params, :direction_key)}
          phx-value-ignore_conflicts={
            if Map.get(action.params, :ignore_conflicts), do: "true", else: "false"
          }
          class={[
            button_style_class(action.style),
            is_disabled && "opacity-40 cursor-not-allowed pointer-events-none"
          ]}
        >
          <%= if show_spinner do %>
            <svg
              class="animate-spin h-4 w-4 shrink-0 text-current"
              xmlns="http://www.w3.org/2000/svg"
              fill="none"
              viewBox="0 0 24 24"
              data-qa="action-spinner"
            >
              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
              </circle>
              <path
                class="opacity-75"
                fill="currentColor"
                d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
              >
              </path>
            </svg>
          <% else %>
            <.icon :if={action.icon} name={action.icon} class="h-4 w-4 shrink-0" />
          <% end %>
          <span>{action.label}</span>
        </button>
      <% end %>
    </div>
    """
  end

  # Helpers for building the exact action list per spec 05 §6.3 and §6.4

  defp build_actions(nil, _design, _pending_questions), do: []

  defp build_actions(task, design, pending_questions) do
    is_merged = merged?(task)
    conflicted = Formatters.has_merge_conflicts?(task) and not task.is_rebasing and not is_merged

    {stage_actions, rebase_offered} =
      if is_merged do
        {[], false}
      else
        build_stage_actions(task, design, conflicted, pending_questions)
      end

    trailing_actions = build_trailing_actions(task, conflicted, rebase_offered)

    stage_actions ++ trailing_actions
  end

  defp build_stage_actions(task, design, conflicted, pending_questions) do
    case task.stage_state do
      :awaiting_approval ->
        build_awaiting_approval_actions(task, design, conflicted)

      :failed ->
        {build_failed_actions(task), false}

      :running ->
        {
          [
            %{
              id: "action-cancel",
              label: "Cancel run",
              kind: :cancel,
              style: :outlined,
              icon: "pi-stop-circle",
              action: "cancel",
              params: %{}
            }
          ],
          false
        }

      :queued ->
        actions = [
          %{
            id: "action-send-back",
            label: "Send back with comments",
            kind: :comment,
            style: :outlined,
            icon: "pi-arrow-bend-up-left",
            action: "comment",
            params: %{}
          }
        ]

        {actions, false}

      :blocked ->
        actions =
          if pending_questions == [] do
            [
              %{
                id: "action-unblock",
                label: "Unblock",
                kind: nil,
                style: :filled,
                icon: "pi-lock-open",
                action: "unblock",
                params: %{}
              }
            ]
          else
            []
          end

        {actions, false}

      _other ->
        {[], false}
    end
  end

  defp build_awaiting_approval_actions(task, design, conflicted) do
    cond do
      task.stage == :ready_to_merge ->
        build_ready_to_merge_actions(task, conflicted)

      task.stage == :design and is_nil(get_picked_key(design, task)) ->
        build_design_pick_actions(task, design)

      Task.gate?(task.stage) ->
        actions = [
          %{
            id: "action-send-back-to-engineer",
            label: "Send back to Engineer",
            kind: :send_back,
            style: :filled,
            icon: "pi-arrow-counter-clockwise",
            action: "send_back_to_engineer",
            params: %{}
          },
          %{
            id: "action-skip",
            label: "Skip",
            kind: :approve,
            style: :outlined,
            icon: "pi-skip-forward",
            action: "skip",
            params: %{}
          },
          %{
            id: "action-send-back",
            label: "Send back with comments",
            kind: :comment,
            style: :outlined,
            icon: "pi-arrow-bend-up-left",
            action: "comment",
            params: %{}
          }
        ]

        {actions, false}

      true ->
        approve_label = if task.stage == :engineer, do: "Send to review", else: "Approve"
        approve_id = if task.stage == :engineer, do: "action-send-to-review", else: "action-approve"

        primary_approve = %{
          id: approve_id,
          label: approve_label,
          kind: :approve,
          style: :filled,
          icon: "pi-check",
          action: "approve",
          params: %{}
        }

        send_back = %{
          id: "action-send-back",
          label: "Send back with comments",
          kind: :comment,
          style: :outlined,
          icon: "pi-arrow-bend-up-left",
          action: "comment",
          params: %{}
        }

        actions =
          if task.stage == :product do
            skip_design_btn = %{
              id: "action-approve-skip-design",
              label: "Approve, skip design",
              kind: :approve,
              style: :outlined,
              icon: "pi-fast-forward",
              action: "approve_skip_design",
              params: %{}
            }

            [primary_approve, skip_design_btn, send_back]
          else
            [primary_approve, send_back]
          end

        {actions, false}
    end
  end

  defp build_ready_to_merge_actions(task, conflicted) do
    draft = task.pr_is_draft == true and is_integer(task.pr_number)

    send_back_btn = %{
      id: "action-send-back-to-engineer",
      label: "Send back to Engineer",
      kind: :send_back,
      style: :outlined,
      icon: "pi-arrow-counter-clockwise",
      action: "send_back_to_engineer",
      params: %{}
    }

    cond do
      conflicted ->
        rebase_btn = %{
          id: "action-rebase",
          label: "Rebase branch",
          kind: :rebase,
          style: :filled,
          icon: "pi-git-merge",
          action: "rebase",
          params: %{}
        }

        if draft do
          mark_ready_btn = %{
            id: "action-mark-ready",
            label: "Mark ready for review",
            kind: :mark_ready,
            style: :outlined,
            icon: "pi-chat-text",
            action: "mark_ready",
            params: %{}
          }

          {[rebase_btn, mark_ready_btn, send_back_btn], true}
        else
          merge_anyway_btn = %{
            id: "action-merge-anyway",
            label: "Merge anyway",
            kind: :merge,
            style: :outlined,
            icon: "pi-git-merge",
            action: "merge",
            params: %{ignore_conflicts: true}
          }

          {[rebase_btn, merge_anyway_btn, send_back_btn], true}
        end

      not draft ->
        merge_btn = %{
          id: "action-merge",
          label: "Merge pull request",
          kind: :merge,
          style: :filled,
          icon: "pi-git-merge",
          action: "merge",
          params: %{ignore_conflicts: false}
        }

        {[merge_btn, send_back_btn], false}

      draft ->
        mark_ready_btn = %{
          id: "action-mark-ready",
          label: "Mark ready for review",
          kind: :mark_ready,
          style: :filled,
          icon: "pi-chat-text",
          action: "mark_ready",
          params: %{}
        }

        {[mark_ready_btn, send_back_btn], false}
    end
  end

  defp build_design_pick_actions(task, design) do
    directions = get_directions(design, task)

    direction_actions =
      Enum.map(directions, fn dir ->
        %{
          id: "action-pick-design-#{dir.key}",
          label: "Use #{dir.title}",
          kind: :approve,
          style: :filled,
          icon: "pi-check",
          action: "pick_design_direction",
          params: %{direction_key: dir.key}
        }
      end)

    send_back = %{
      id: "action-send-back",
      label: "Send back with comments",
      kind: :comment,
      style: :outlined,
      icon: "pi-arrow-bend-up-left",
      action: "comment",
      params: %{}
    }

    {Enum.reverse([send_back | Enum.reverse(direction_actions)]), false}
  end

  defp build_failed_actions(task) do
    stage_specific =
      case task.stage do
        :demo ->
          [
            %{
              id: "action-rerecord-demo",
              label: "Re-record demo",
              kind: :retry,
              style: :filled,
              icon: "pi-arrow-clockwise",
              action: "rerecord_demo",
              params: %{}
            },
            %{
              id: "action-decline-demo",
              label: "Continue without a demo",
              kind: :approve,
              style: :outlined,
              icon: "pi-arrow-right",
              action: "decline_demo",
              params: %{}
            }
          ]

        :design ->
          [
            %{
              id: "action-recheck-design",
              label: "Design is done",
              kind: :recheck_design,
              style: :filled,
              icon: "pi-check-square",
              action: "recheck_design",
              params: %{}
            },
            %{
              id: "action-retry",
              label: "Re-run designer",
              kind: :retry,
              style: :outlined,
              icon: "pi-arrow-clockwise",
              action: "retry",
              params: %{}
            }
          ]

        _other ->
          [
            %{
              id: "action-retry",
              label: "Retry",
              kind: :retry,
              style: :filled,
              icon: "pi-arrow-clockwise",
              action: "retry",
              params: %{}
            }
          ]
      end

    send_back = %{
      id: "action-send-back",
      label: "Send back with comments",
      kind: :comment,
      style: :outlined,
      icon: "pi-arrow-bend-up-left",
      action: "comment",
      params: %{}
    }

    Enum.reverse([send_back | Enum.reverse(stage_specific)])
  end

  defp build_trailing_actions(task, conflicted, rebase_offered) do
    chat_btn = %{
      id: "action-chat",
      label: "Chat",
      kind: nil,
      style: :outlined,
      icon: "pi-chat-circle",
      action: "chat",
      params: %{}
    }

    cleanup_btn = %{
      id: "action-cleanup",
      label: "Clean up",
      kind: :cleanup,
      style: :text,
      icon: "pi-trash",
      action: "cleanup",
      params: %{}
    }

    trailing = [chat_btn]

    trailing =
      if conflicted and not rebase_offered and task.stage_state != :running do
        rebase_btn = %{
          id: "action-rebase",
          label: "Rebase branch",
          kind: :rebase,
          style: :outlined,
          icon: "pi-git-merge",
          action: "rebase",
          params: %{}
        }

        [rebase_btn | trailing]
      else
        trailing
      end

    has_diff = not Task.before?(task.stage, :engineer)

    trailing =
      if has_diff do
        diff_btn = %{
          id: "action-view-diff",
          label: "View diff",
          kind: nil,
          style: :text,
          icon: "pi-git-diff",
          action: "diff",
          params: %{}
        }

        [diff_btn | trailing]
      else
        trailing
      end

    Enum.reverse([cleanup_btn | trailing])
  end

  defp action_disabled?(_task, nil, _running_kind), do: false

  defp action_disabled?(task, kind, running_kind) do
    is_busy =
      running_kind != nil or
        (is_binary(task.active_chat_role_id) and task.active_chat_role_id != "") or
        (task.stage_state == :running and kind != :cancel)

    is_busy
  end

  defp button_style_class(:filled) do
    "px-4 py-2 rounded-full text-xs font-semibold inline-flex items-center gap-2 transition-colors bg-blue-600 dark:bg-blue-500 text-white hover:bg-blue-600 dark:hover:bg-blue-500/90 cursor-pointer shadow-xs"
  end

  defp button_style_class(:outlined) do
    "px-4 py-2 rounded-full text-xs font-semibold inline-flex items-center gap-2 transition-colors border border-slate-500 dark:border-slate-400 text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer"
  end

  defp button_style_class(:text) do
    "px-3 py-2 rounded-full text-xs font-semibold inline-flex items-center gap-2 transition-colors text-blue-600 dark:text-blue-500 hover:bg-slate-50 dark:hover:bg-slate-800 cursor-pointer"
  end

  defp merged?(task) do
    task.stage == :merged or is_struct(task.merged_at, DateTime)
  end

  defp get_picked_key(design, task) do
    cond do
      is_map(design) and Map.has_key?(design, :picked_key) ->
        design.picked_key

      is_list(Map.get(task, :designs)) and task.designs != [] ->
        latest = Enum.max_by(task.designs, & &1.version)
        latest.picked_key

      true ->
        nil
    end
  end

  defp get_directions(design, task) do
    cond do
      is_map(design) and is_list(Map.get(design, :directions)) ->
        design.directions

      is_list(Map.get(task, :designs)) and task.designs != [] ->
        latest = Enum.max_by(task.designs, & &1.version)
        latest.directions || []

      true ->
        []
    end
  end
end
