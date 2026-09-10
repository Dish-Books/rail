defmodule Rail.Domain.FormattersTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.Scratch, only: [capture: 3]

  alias Rail.Domain.Formatters
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Formatters Workspace",
        external_id: "lin_ws_formatters",
        token: "lin_api_token_formatters",
        webhook_secret: "whsec_formatters"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Formatters Project 7701",
        github_repo: "org/formatters-7701",
        github_installation_id: 7701,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_formatters_7701",
        linear_team_key: "P7701",
        clone_path: "/tmp/repos/formatters-7701",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_formatters_1",
      "identifier" => "FMT-1",
      "title" => "Formatters Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Formatters Issue")

    LinearMock.mock_update_issue_success(%{"id" => "lin_formatters_1"})

    {:ok, task} = Pipeline.bring_local(scope, issue)

    %{project: project, issue: issue, task: task}
  end

  describe "summarize_ask/1" do
    test "returns empty string on nil or blank input" do
      assert Formatters.summarize_ask(nil) == ""
      assert Formatters.summarize_ask("") == ""
      assert Formatters.summarize_ask("   \n \t \n  ") == ""
    end

    test "extracts first non-blank line and returns as-is if <= 90 chars" do
      input = "\n   \nFix the navigation bar alignment\nDetails on second line"
      assert Formatters.summarize_ask(input) == "Fix the navigation bar alignment"

      exact_90 = String.duplicate("a", 90)
      assert Formatters.summarize_ask(exact_90) == exact_90
    end

    test "cuts at whitespace boundary before char 90 and appends ellipsis" do
      # 80 chars word + space + 20 chars
      p1 = String.duplicate("w", 80)
      p2 = String.duplicate("x", 20)
      input = "#{p1} #{p2}"

      result = Formatters.summarize_ask(input)
      assert result == "#{p1}…"
      assert String.length(result) == 81
    end

    test "cuts at char 90 when char 90 is whitespace" do
      # 90 chars + space + more
      p1 = String.duplicate("a", 90)
      input = "#{p1} more words after"

      result = Formatters.summarize_ask(input)
      assert result == "#{p1}…"
    end

    test "cuts at 90 with ellipsis when there is no whitespace boundary" do
      unbroken = String.duplicate("z", 110)
      result = Formatters.summarize_ask(unbroken)

      assert result == "#{String.slice(unbroken, 0, 90)}…"
    end
  end

  describe "overview_detail_for/2" do
    test "returns nil for nil task or non-failed task with no error" do
      assert is_nil(Formatters.overview_detail_for(nil))

      task_normal = %{
        stage: :architect,
        stage_state: :awaiting_approval,
        runs: %{architect: %{status: :completed, error: "Old error"}}
      }

      assert is_nil(Formatters.overview_detail_for(task_normal))
    end

    test "picks first non-blank line of task.error", %{task: _task} do
      task = %{
        error: "\n   \nFirst non-blank error line\nSecond error line",
        stage: :engineer,
        stage_state: :failed
      }

      assert Formatters.overview_detail_for(task) == "First non-blank error line"
    end

    test "falls back to failed run error when task.error is absent or blank", %{task: _task} do
      task = %{
        error: "   ",
        stage: :engineer,
        stage_state: :failed,
        current_role_id: "engineer",
        runs: %{
          "engineer" => %{
            status: :failed,
            error: "   \nRun failed with compiler crash\nStack trace line"
          }
        }
      }

      assert Formatters.overview_detail_for(task) == "Run failed with compiler crash"
    end

    test "uses passed runs map when provided", %{task: _task} do
      task = %{
        stage: :engineer,
        stage_state: :failed,
        current_role_id: :engineer
      }

      runs = %{
        engineer: %{error: "External runs map error"}
      }

      assert Formatters.overview_detail_for(task, runs) == "External runs map error"
    end

    test "collapses consecutive whitespace and trims line", %{task: _task} do
      task = %{
        error: "   Failed   to    build    target    main.dart   ",
        stage: :engineer,
        stage_state: :failed
      }

      assert Formatters.overview_detail_for(task) == "Failed to build target main.dart"
    end

    test "caps at 140 characters with ellipsis when line exceeds 140 chars", %{task: _task} do
      long_line = String.duplicate("A", 200)
      task = %{error: long_line, stage: :engineer, stage_state: :failed}

      expected = String.duplicate("A", 140) <> "..."
      assert Formatters.overview_detail_for(task) == expected
    end

    test "does not append ellipsis when line is 140 characters or fewer", %{task: _task} do
      exact_140 = String.duplicate("B", 140)
      task = %{error: exact_140, stage: :engineer, stage_state: :failed}

      assert Formatters.overview_detail_for(task) == exact_140
    end
  end

  describe "stage_label/2" do
    test "returns 'Waiting on you' for nil task or unknown state" do
      assert Formatters.stage_label(nil) == "Waiting on you"
      assert Formatters.stage_label(%{stage_state: :unknown_state}) == "Waiting on you"
    end

    test "active chat role has highest precedence", %{task: _task} do
      task = %{
        active_chat_role_id: "engineer",
        stage: :architect,
        stage_state: :failed
      }

      assert Formatters.stage_label(task) == "Chatting with Engineer"

      # Custom role name in opts
      assert Formatters.stage_label(task, role_name: "Code Expert") == "Chatting with Code Expert"

      # Custom roles list in opts
      roles = [%{id: "engineer", name: "Lead Engineer"}]
      assert Formatters.stage_label(task, roles: roles) == "Chatting with Lead Engineer"

      # Unmatched custom role in roles list falls back to default
      roles_other = [%{id: "other", name: "Other"}]
      assert Formatters.stage_label(task, roles: roles_other) == "Chatting with Engineer"

      # Default role names: product, designer, reviewer, qa, qa_lead, demo
      assert Formatters.stage_label(%{active_chat_role_id: "product"}) == "Chatting with Product"
      assert Formatters.stage_label(%{active_chat_role_id: "design"}) == "Chatting with Designer"
      assert Formatters.stage_label(%{active_chat_role_id: "designer"}) == "Chatting with Designer"
      assert Formatters.stage_label(%{active_chat_role_id: "architect"}) == "Chatting with Architect"
      assert Formatters.stage_label(%{active_chat_role_id: "review"}) == "Chatting with Reviewer"
      assert Formatters.stage_label(%{active_chat_role_id: "reviewer"}) == "Chatting with Reviewer"
      assert Formatters.stage_label(%{active_chat_role_id: "qa"}) == "Chatting with QA"
      assert Formatters.stage_label(%{active_chat_role_id: "qa_lead"}) == "Chatting with QA Lead"
      assert Formatters.stage_label(%{active_chat_role_id: "demo"}) == "Chatting with Demo"
      assert Formatters.stage_label(%{active_chat_role_id: "security_lead"}) == "Chatting with Security Lead"
    end

    test "rebase status formatting" do
      t_queued = %{is_rebasing: true, stage_state: :queued}
      assert Formatters.stage_label(t_queued) == "Queued to rebase"

      # Waiting to retry rebase
      future_time = ~U[2026-01-01 12:00:00Z]
      now_time = ~U[2026-01-01 11:00:00Z]
      t_retry = %{is_rebasing: true, stage_state: :queued, retry_after: future_time}
      assert Formatters.stage_label(t_retry, now: now_time) == "Retrying the rebase shortly"

      t_running = %{is_rebasing: true, stage_state: :running}
      assert Formatters.stage_label(t_running) == "Rebasing the branch"

      t_blocked = %{is_rebasing: true, stage_state: :blocked}
      assert Formatters.stage_label(t_blocked) == "Rebase needs an answer"

      t_paused = %{is_rebasing: true, stage_state: :paused_question}
      assert Formatters.stage_label(t_paused) == "Rebase needs an answer"

      t_failed = %{is_rebasing: true, stage_state: :failed}
      assert Formatters.stage_label(t_failed) == "Rebase failed"

      t_other = %{is_rebasing: true, stage_state: :idle}
      assert Formatters.stage_label(t_other) == "Queued to rebase"
    end

    test "rework cycle suffix" do
      # On or after engineer with rework_cycles > 0
      t_eng = %{stage: :engineer, stage_state: :running, rework_cycles: 2}
      assert Formatters.stage_label(t_eng) == "Engineer running · rework 2 of 5"

      # Custom rework ceiling
      assert Formatters.stage_label(t_eng, rework_ceiling: 8) == "Engineer running · rework 2 of 8"

      # Before engineer (e.g. architect): no rework suffix
      t_arch = %{stage: :architect, stage_state: :running, rework_cycles: 2}
      assert Formatters.stage_label(t_arch) == "Architect running"

      # rework_cycles = 0: no rework suffix
      t_zero = %{stage: :engineer, stage_state: :running, rework_cycles: 0}
      assert Formatters.stage_label(t_zero) == "Engineer running"
    end

    test "queued state with conflicts, retry, and normal" do
      t_conflicted = %{stage: :engineer, stage_state: :queued, shows_as_conflicted: true}
      assert Formatters.stage_label(t_conflicted) == "Conflicts - needs a rebase"

      future_time = ~U[2026-01-01 12:00:00Z]
      now_time = ~U[2026-01-01 11:00:00Z]
      t_retry = %{stage: :review, stage_state: :queued, retry_after: future_time}
      assert Formatters.stage_label(t_retry, now: now_time) == "Retrying Review shortly"

      t_normal = %{stage: :qa, stage_state: :queued}
      assert Formatters.stage_label(t_normal) == "Queued for QA"
    end

    test "running, blocked, failed states" do
      assert Formatters.stage_label(%{stage: :qa_lead, stage_state: :running}) == "QA Lead running"
      assert Formatters.stage_label(%{stage: :demo, stage_state: :blocked}) == "Demo needs an answer"
      assert Formatters.stage_label(%{stage: :demo, stage_state: :blocked_rework}) == "Demo needs an answer"
      assert Formatters.stage_label(%{stage: :engineer, stage_state: :failed}) == "Engineer failed"
    end

    test "awaiting_approval state across stages and design picked state" do
      assert Formatters.stage_label(%{stage: :engineer, stage_state: :awaiting_approval, shows_as_conflicted: true}) ==
               "Conflicts - needs a rebase"

      assert Formatters.stage_label(%{stage: :product, stage_state: :awaiting_approval}) == "Review the ticket"
      assert Formatters.stage_label(%{stage: :design, stage_state: :awaiting_approval}) == "Pick a design direction"

      # Design with picked key in map or opts
      assert Formatters.stage_label(%{stage: :design, stage_state: :awaiting_approval, design: %{picked_key: "dir-1"}}) ==
               "Review the design"

      assert Formatters.stage_label(%{stage: :design, stage_state: :awaiting_approval, design_picked_key: "dir-1"}) ==
               "Review the design"

      assert Formatters.stage_label(%{stage: :design, stage_state: :awaiting_approval}, design_picked: true) ==
               "Review the design"

      assert Formatters.stage_label(%{stage: :architect, stage_state: :awaiting_approval}) == "Review the plan"
      assert Formatters.stage_label(%{stage: :engineer, stage_state: :awaiting_approval}) == "Ready to send to review"
      assert Formatters.stage_label(%{stage: :review, stage_state: :awaiting_approval}) == "Review needs your call"
      assert Formatters.stage_label(%{stage: :qa, stage_state: :awaiting_approval}) == "QA needs your call"
      assert Formatters.stage_label(%{stage: :qa_lead, stage_state: :awaiting_approval}) == "QA needs your call"
      assert Formatters.stage_label(%{stage: :demo, stage_state: :awaiting_approval}) == "Review the demo"
      assert Formatters.stage_label(%{stage: :ready_to_merge, stage_state: :awaiting_approval}) == "Ready to merge"
      assert Formatters.stage_label(%{stage: :custom_stage, stage_state: :awaiting_approval}) == "Waiting on you"
    end
  end

  describe "format_tokens/2" do
    test "formats integers and floats with and without suffix" do
      assert Formatters.format_tokens(nil) == "0"
      assert Formatters.format_tokens(nil, suffix: true) == "0 tokens"

      assert Formatters.format_tokens(0) == "0"
      assert Formatters.format_tokens(1) == "1"
      assert Formatters.format_tokens(1, suffix: true) == "1 token"

      assert Formatters.format_tokens(500) == "500"
      assert Formatters.format_tokens(500, suffix: true) == "500 tokens"

      assert Formatters.format_tokens(1_500) == "1.5K"
      assert Formatters.format_tokens(2_000) == "2K"
      assert Formatters.format_tokens(1_230_000) == "1.23M"
      assert Formatters.format_tokens(2_000_000) == "2M"
      assert Formatters.format_tokens(2_500_000) == "2.5M"

      # Floats
      assert Formatters.format_tokens(1_500.0) == "1.5K"
    end
  end

  describe "format_cost/2" do
    test "formats decimals, floats, ints, and binary strings across currencies" do
      assert Formatters.format_cost(nil) == ""

      assert Formatters.format_cost(Decimal.new("0.0250")) == "$0.0250"
      assert Formatters.format_cost(0.025) == "$0.0250"
      assert Formatters.format_cost(1) == "$1.0000"
      assert Formatters.format_cost("12.50") == "$12.5000"

      assert Formatters.format_cost(Decimal.new("12.3456"), "EUR") == "12.3456 EUR"
      assert Formatters.format_cost(Decimal.new("5.5000"), currency: "GBP") == "5.5000 GBP"
    end
  end

  describe "format_duration/1" do
    test "formats duration from seconds" do
      assert Formatters.format_duration(nil) == ""
      assert Formatters.format_duration(0) == "0s"
      assert Formatters.format_duration(-5) == "0s"

      assert Formatters.format_duration(45) == "45s"
      assert Formatters.format_duration(65) == "1m 5s"
      assert Formatters.format_duration(3600) == "1h 0m 0s"
      assert Formatters.format_duration(3665) == "1h 1m 5s"
      assert Formatters.format_duration(3665.4) == "1h 1m 5s"
    end
  end

  describe "edge cases and type variations" do
    test "overview_detail_for handles whitespace-only error and non-map runs" do
      t_whitespace = %{stage_state: :failed, runs: %{engineer: %{error: "  \n  \n  "}}}
      assert Formatters.overview_detail_for(t_whitespace) == nil

      t_no_runs = %{stage_state: :failed, runs: nil}
      assert Formatters.overview_detail_for(t_no_runs) == nil

      t_invalid_runs = %{stage_state: :failed, current_role_id: :engineer, runs: "invalid"}
      assert Formatters.overview_detail_for(t_invalid_runs) == nil

      assert Formatters.overview_detail_for(nil) == nil
    end

    test "stage_label handles is_waiting_to_retry boolean flag" do
      t_retry_true = %{stage: :engineer, stage_state: :queued, is_rebasing: true, is_waiting_to_retry: true}
      assert Formatters.stage_label(t_retry_true) == "Retrying the rebase shortly"

      t_retry_false = %{stage: :engineer, stage_state: :queued, is_rebasing: true, is_waiting_to_retry: false}
      assert Formatters.stage_label(t_retry_false) == "Queued to rebase"
    end

    test "stage_label handles has_merge_conflicts and mergeability variations" do
      t_hmc = %{stage: :engineer, stage_state: :queued, has_merge_conflicts: true}
      assert Formatters.stage_label(t_hmc) == "Conflicts - needs a rebase"

      t_merge_atom = %{stage: :engineer, stage_state: :queued, mergeability: :conflicts}
      assert Formatters.stage_label(t_merge_atom) == "Conflicts - needs a rebase"

      t_merge_str = %{stage: :engineer, stage_state: :queued, mergeability: "conflicts"}
      assert Formatters.stage_label(t_merge_str) == "Conflicts - needs a rebase"
    end

    test "stage_label and get_field handle struct, string keys, and invalid atoms", %{task: _task} do
      # Struct task
      uri_task = %URI{scheme: "https", host: "example.com"}
      assert Formatters.stage_label(uri_task) == "Waiting on you"

      # String key map
      str_task = %{"stage" => "engineer", "stage_state" => "running"}
      assert Formatters.stage_label(str_task) == "Engineer running"

      # Valid string stage that converts to atom
      str_stage_task = %{stage: "engineer", stage_state: :running}
      assert Formatters.stage_label(str_stage_task) == "Engineer running"

      # String stage that does not exist as atom
      bad_task = %{stage: "totally_unknown_stage_string_xyz", stage_state: :running}
      assert Formatters.stage_label(bad_task) == " running"

      # Non-atom / non-string stage
      non_atom_task = %{stage: 999, stage_state: :running}
      assert Formatters.stage_label(non_atom_task) == " running"

      # Nil and non-map task
      assert Formatters.stage_label(nil) == "Waiting on you"
      assert Formatters.stage_label(12_345) == "Waiting on you"
    end
  end

  describe "stage_state_icon/1" do
    test "returns expected icon across all states and stages" do
      assert Formatters.stage_state_icon(%{active_chat_role_id: "engineer"}) == "pi-chat-circle"
      assert Formatters.stage_state_icon(%{shows_as_conflicted: true}) == "pi-git-branch"
      assert Formatters.stage_state_icon(%{stage_state: :running}) == "pi-play-circle"
      assert Formatters.stage_state_icon(%{stage_state: :queued}) == "pi-clock"
      assert Formatters.stage_state_icon(%{stage_state: :blocked}) == "pi-question"
      assert Formatters.stage_state_icon(%{stage_state: :paused_question}) == "pi-question"
      assert Formatters.stage_state_icon(%{stage_state: :awaiting_approval, stage: :ready_to_merge}) == "pi-git-merge"
      assert Formatters.stage_state_icon(%{stage_state: :awaiting_approval, stage: :engineer}) == "pi-chat-text"
      assert Formatters.stage_state_icon(%{stage_state: :failed}) == "pi-warning-circle"
      assert Formatters.stage_state_icon(%{stage_state: :unknown_state}) == "pi-question"
    end
  end

  describe "stage_state_color/1 and stage_state_color_class/2" do
    test "returns semantic color atom and tailwind classes" do
      t_chat = %{active_chat_role_id: "engineer"}
      assert Formatters.stage_state_color(t_chat) == :primary
      assert Formatters.stage_state_color_class(t_chat, :text) =~ "text-blue-600 dark:text-blue-500"
      assert Formatters.stage_state_color_class(t_chat, :chip) =~ "bg-blue-100 dark:bg-blue-900"

      t_conflicted = %{shows_as_conflicted: true}
      assert Formatters.stage_state_color(t_conflicted) == :amber
      assert Formatters.stage_state_color_class(t_conflicted, :text) =~ "text-amber-700"
      assert Formatters.stage_state_color_class(t_conflicted, :chip) =~ "bg-amber-100"

      t_run = %{stage_state: :running}
      assert Formatters.stage_state_color(t_run) == :primary

      t_block = %{stage_state: :blocked}
      assert Formatters.stage_state_color(t_block) == :amber

      t_appr = %{stage_state: :awaiting_approval}
      assert Formatters.stage_state_color(t_appr) == :amber

      t_queue = %{stage_state: :queued}
      assert Formatters.stage_state_color(t_queue) == :outline
      assert Formatters.stage_state_color_class(t_queue, :text) =~ "text-slate-500 dark:text-slate-400"
      assert Formatters.stage_state_color_class(t_queue, :chip) =~ "bg-slate-100 dark:bg-slate-700"

      t_fail = %{stage_state: :failed}
      assert Formatters.stage_state_color(t_fail) == :error
      assert Formatters.stage_state_color_class(t_fail, :text) =~ "text-red-600 dark:text-red-500"
      assert Formatters.stage_state_color_class(t_fail, :chip) =~ "bg-red-100 dark:bg-red-900"

      t_other = %{stage_state: :unknown_state}
      assert Formatters.stage_state_color(t_other) == :outline
    end
  end

  describe "shows_as_conflicted?/1 and has_merge_conflicts?/1" do
    test "detects merge conflicts accurately" do
      assert Formatters.shows_as_conflicted?(%{shows_as_conflicted: true})
      assert Formatters.shows_as_conflicted?(%{conflicted: true})
      assert Formatters.shows_as_conflicted?(%{has_merge_conflicts: true, is_rebasing: false, stage_state: :queued})

      assert Formatters.shows_as_conflicted?(%{
               mergeability: :conflicts,
               is_rebasing: false,
               stage_state: :awaiting_approval
             })

      assert Formatters.shows_as_conflicted?(%{mergeability: "conflicting", is_rebasing: false, stage_state: :queued})

      # False if rebasing
      refute Formatters.shows_as_conflicted?(%{has_merge_conflicts: true, is_rebasing: true, stage_state: :queued})

      # False if running
      refute Formatters.shows_as_conflicted?(%{has_merge_conflicts: true, is_rebasing: false, stage_state: :running})

      # Non conflicted
      refute Formatters.shows_as_conflicted?(%{has_merge_conflicts: false, stage_state: :queued})
    end
  end

  describe "uses_design?/2" do
    test "returns true for product and design stages" do
      assert Formatters.uses_design?(%{stage: :product})
      assert Formatters.uses_design?(%{stage: :design})
    end

    test "returns false for stages past design unless designer run exists" do
      refute Formatters.uses_design?(%{stage: :architect})
      refute Formatters.uses_design?(nil)

      assert Formatters.uses_design?(%{stage: :architect}, has_designer_run: true)
      assert Formatters.uses_design?(%{stage: :engineer, runs: %{"designer" => %{}}})
      assert Formatters.uses_design?(%{stage: :engineer, runs: %{designer: %{}}})
      assert Formatters.uses_design?(%{stage: :engineer, role_runs: [%{role_id: "designer"}]})
      assert Formatters.uses_design?(%{stage: :engineer, role_runs: [%{role: %{stage: :design}}]})
    end
  end

  describe "ticket_for/1 and plan_for/1" do
    test "ticket_for returns ticket content or fallback" do
      assert Formatters.ticket_for(%{description: "Build user auth\n\n## Implementation plan\n1. Do stuff"}) ==
               "Build user auth"

      assert Formatters.ticket_for(%{description: "   "}) == "_No ticket body yet._"
      assert Formatters.ticket_for(nil) == "_No ticket body yet._"
    end

    test "plan_for returns stored plan or plan from description split", %{task: task} do
      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          description: "Ticket text\n\n## Implementation plan\nStep 1\nStep 2"
        })

      assert Formatters.plan_for(task) == "## Implementation plan\nStep 1\nStep 2"

      # Stored plan takes precedence
      expect(File, :exists?, 2, fn path -> String.ends_with?(path, "plan.md") end)

      expect(File, :read!, fn _path -> "# Database Plan" end)

      {:ok, _captured} = capture(:architect, task, "/tmp/rail_scratch/plan_7710")

      {:ok, _plan} = Pipeline.get_plan(system_scope(), task)
      assert Formatters.plan_for(task) == "# Database Plan"

      # Task with plans association loaded
      task_with_plans = %{plans: [%Rail.Pipeline.Schemas.Plan{content: "# In-memory plan"}]}
      assert Formatters.plan_for(task_with_plans) == "# In-memory plan"

      # Empty plan returns nil
      assert is_nil(Formatters.plan_for(%{description: "Just a ticket"}))
    end

    test "rework ceiling computed from rework_budget_base + 5 or explicit rework_ceiling" do
      t_base = %{stage: :engineer, stage_state: :running, rework_cycles: 2, rework_budget_base: 3}
      assert Formatters.stage_label(t_base) == "Engineer running · rework 2 of 8"

      t_custom = %{stage: :engineer, stage_state: :running, rework_cycles: 1, rework_ceiling: 9}
      assert Formatters.stage_label(t_custom) == "Engineer running · rework 1 of 9"

      # stage_state_color_class with default 1-arg
      assert Formatters.stage_state_color_class(t_base) == "text-blue-600 dark:text-blue-500"

      # uses_design? with atom keys in map
      assert Formatters.uses_design?(%{stage: :engineer}, role_runs: %{design: true})
    end
  end

  describe "role_icon_for/1" do
    test "maps known icon names and defaults to help_outline" do
      assert Formatters.role_icon_for("code") == "pi-code"
      assert Formatters.role_icon_for("bug_report") == "pi-bug"
      assert Formatters.role_icon_for("verified") == "pi-seal-check-fill"
      assert Formatters.role_icon_for("fact_check") == "pi-check-square-fill"
      assert Formatters.role_icon_for("rate_review") == "pi-chat-text-fill"
      assert Formatters.role_icon_for("alt_route") == "pi-arrows-split"
      assert Formatters.role_icon_for("travel_explore") == "pi-globe-hemisphere-west"
      assert Formatters.role_icon_for("assignment") == "pi-clipboard-text"
      assert Formatters.role_icon_for("architecture") == "pi-compass-tool"
      assert Formatters.role_icon_for("palette") == "pi-palette"
      assert Formatters.role_icon_for("videocam") == "pi-video-camera-fill"
      assert Formatters.role_icon_for("pi-terminal-window") == "pi-terminal-window"
      assert Formatters.role_icon_for("terminal") == "pi-question"
      assert Formatters.role_icon_for("unknown") == "pi-question"
      assert Formatters.role_icon_for(nil) == "pi-question"
    end
  end

  describe "format_run_status/1" do
    test "formats atom and string statuses into lowerCamel" do
      assert Formatters.format_run_status(:running) == "running"
      assert Formatters.format_run_status(:blocked_on_input) == "blockedOnInput"
      assert Formatters.format_run_status("completed") == "completed"
      assert Formatters.format_run_status("in_progress") == "inProgress"
      assert Formatters.format_run_status(nil) == ""
      assert Formatters.format_run_status("") == ""
    end
  end
end
