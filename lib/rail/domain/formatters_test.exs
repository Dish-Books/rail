defmodule Rail.Domain.FormattersTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Formatters

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

    test "picks first non-blank line of task.error" do
      task = %{
        error: "\n   \nFirst non-blank error line\nSecond error line",
        stage: :engineer,
        stage_state: :failed
      }

      assert Formatters.overview_detail_for(task) == "First non-blank error line"
    end

    test "falls back to failed run error when task.error is absent or blank" do
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

    test "uses passed runs map when provided" do
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

    test "collapses consecutive whitespace and trims line" do
      task = %{
        error: "   Failed   to    build    target    main.dart   ",
        stage: :engineer,
        stage_state: :failed
      }

      assert Formatters.overview_detail_for(task) == "Failed to build target main.dart"
    end

    test "caps at 140 characters with ellipsis when line exceeds 140 chars" do
      long_line = String.duplicate("A", 200)
      task = %{error: long_line, stage: :engineer, stage_state: :failed}

      expected = String.duplicate("A", 140) <> "..."
      assert Formatters.overview_detail_for(task) == expected
    end

    test "does not append ellipsis when line is 140 characters or fewer" do
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

    test "active chat role has highest precedence" do
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

    test "stage_label and get_field handle struct, string keys, and invalid atoms" do
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
end
