defmodule Rail.Domain.FormattersTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Formatters
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Runs.Schemas.Run
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
        default_branch: "main",
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

    {:ok, task} = Pipeline.create_task(issue, :product)

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
        runs: %{architect: %{status: :completed, error: "Old error"}}
      }

      assert is_nil(Formatters.overview_detail_for(task_normal))
    end

    test "picks first non-blank line of task.error", %{task: _task} do
      task = %{
        error: "\n   \nFirst non-blank error line\nSecond error line",
        stage: :engineer
      }

      assert Formatters.overview_detail_for(task) == "First non-blank error line"
    end

    test "falls back to failed run error when task.error is absent or blank", %{task: _task} do
      task = %{
        error: "   ",
        stage: :engineer,
        current_role_id: "engineer",
        run: %Run{status: :finished, error: "failed"},
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
        current_role_id: :engineer,
        run: %Run{status: :finished, error: "failed"}
      }

      runs = %{
        engineer: %{error: "External runs map error"}
      }

      assert Formatters.overview_detail_for(task, runs) == "External runs map error"
    end

    test "collapses consecutive whitespace and trims line", %{task: _task} do
      task = %{
        error: "   Failed   to    build    target    main.dart   ",
        stage: :engineer
      }

      assert Formatters.overview_detail_for(task) == "Failed to build target main.dart"
    end

    test "caps at 140 characters with ellipsis when line exceeds 140 chars", %{task: _task} do
      long_line = String.duplicate("A", 200)
      task = %{error: long_line, stage: :engineer}

      expected = String.duplicate("A", 140) <> "..."
      assert Formatters.overview_detail_for(task) == expected
    end

    test "does not append ellipsis when line is 140 characters or fewer", %{task: _task} do
      exact_140 = String.duplicate("B", 140)
      task = %{error: exact_140, stage: :engineer}

      assert Formatters.overview_detail_for(task) == exact_140
    end
  end

  describe "stage_label/2" do
    test "returns 'Waiting on you' for nil task" do
      assert Formatters.stage_label(nil) == "Waiting on you"
    end

    test "names the stage and what its run is doing" do
      assert Formatters.stage_label(%{stage: :qa_lead, run: %Run{status: :running}}) == "QA Lead running"

      assert Formatters.stage_label(%{stage: :demo, run: %Run{status: :blocked_on_input}}) == "Demo needs an answer"

      assert Formatters.stage_label(%{stage: :engineer, run: %Run{status: :finished, error: "boom"}}) ==
               "Engineer failed"

      assert Formatters.stage_label(%{stage: :engineer, run: %Run{status: :finished}}) == "Engineer stopped"
      assert Formatters.stage_label(%{stage: :qa}) == "Queued for QA"
    end

    test "a stage that is done says what the human has to decide" do
      done = %Run{status: :finished, stage_outcome: :done}

      assert Formatters.stage_label(%{stage: :product, run: done}) == "Review the ticket"
      assert Formatters.stage_label(%{stage: :design, run: done}) == "Pick a design direction"
      assert Formatters.stage_label(%{stage: :design, run: done}, design_picked: true) == "Review the design"
      assert Formatters.stage_label(%{stage: :architect, run: done}) == "Review the plan"
      assert Formatters.stage_label(%{stage: :engineer, run: done}) == "Ready to send to review"
      assert Formatters.stage_label(%{stage: :review, run: done}) == "Review needs your call"
      assert Formatters.stage_label(%{stage: :qa, run: done}) == "QA needs your call"
      assert Formatters.stage_label(%{stage: :qa_lead, run: done}) == "QA needs your call"
      assert Formatters.stage_label(%{stage: :demo, run: done}) == "Review the demo"
      assert Formatters.stage_label(%{stage: :ready_to_merge, run: done}) == "Ready to merge"
      assert Formatters.stage_label(%{stage: :debugger, run: done}) == "Waiting on you"
    end

    test "a conflicted branch says so rather than naming the stage" do
      conflicted = %{stage: :engineer, shows_as_conflicted: true}

      assert Formatters.stage_label(conflicted) == "Conflicts - needs a rebase"

      done = %Run{status: :finished, stage_outcome: :done}

      assert Formatters.stage_label(%{stage: :engineer, shows_as_conflicted: true, run: done}) ==
               "Conflicts - needs a rebase"
    end

    test "rebase status formatting" do
      assert Formatters.stage_label(%{is_rebasing: true}) == "Queued to rebase"

      assert Formatters.stage_label(%{is_rebasing: true, run: %Run{status: :running}}) == "Rebasing the branch"

      assert Formatters.stage_label(%{is_rebasing: true, run: %Run{status: :blocked_on_input}}) ==
               "Rebase needs an answer"

      assert Formatters.stage_label(%{is_rebasing: true, run: %Run{status: :finished, error: "boom"}}) ==
               "Rebase failed"

      assert Formatters.stage_label(%{is_rebasing: true, run: %Run{status: :finished}}) == "Rebase stopped"
    end

    test "rework cycle suffix" do
      running = %Run{status: :running}

      t_eng = %{stage: :engineer, rework_cycles: 2, run: running}
      assert Formatters.stage_label(t_eng) == "Engineer running · rework 2 of 5"
      assert Formatters.stage_label(t_eng, rework_ceiling: 8) == "Engineer running · rework 2 of 8"

      # Before engineer there is nothing to have reworked yet.
      t_arch = %{stage: :architect, rework_cycles: 2, run: running}
      assert Formatters.stage_label(t_arch) == "Architect running"

      t_zero = %{stage: :engineer, rework_cycles: 0, run: running}
      assert Formatters.stage_label(t_zero) == "Engineer running"
    end

    test "a task waiting to retry says so while it queues" do
      t_retry = %{stage: :review, is_waiting_to_retry: true}
      assert Formatters.stage_label(t_retry) == "Retrying Review shortly"
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
      t_whitespace = %{runs: %{engineer: %{error: "  \n  \n  "}}}
      assert Formatters.overview_detail_for(t_whitespace) == nil

      t_no_runs = %{runs: nil}
      assert Formatters.overview_detail_for(t_no_runs) == nil

      t_invalid_runs = %{current_role_id: :engineer, runs: "invalid"}
      assert Formatters.overview_detail_for(t_invalid_runs) == nil

      assert Formatters.overview_detail_for(nil) == nil
    end

    test "stage_label handles is_waiting_to_retry boolean flag" do
      t_retry_true = %{stage: :engineer, is_rebasing: true, is_waiting_to_retry: true}
      assert Formatters.stage_label(t_retry_true) == "Retrying the rebase shortly"

      t_retry_false = %{stage: :engineer, is_rebasing: true, is_waiting_to_retry: false}
      assert Formatters.stage_label(t_retry_false) == "Queued to rebase"
    end

    test "stage_label handles has_merge_conflicts and mergeability variations" do
      t_hmc = %{stage: :engineer, has_merge_conflicts: true}
      assert Formatters.stage_label(t_hmc) == "Conflicts - needs a rebase"

      t_merge_atom = %{stage: :engineer, mergeability: :conflicts}
      assert Formatters.stage_label(t_merge_atom) == "Conflicts - needs a rebase"

      t_merge_str = %{stage: :engineer, mergeability: "conflicts"}
      assert Formatters.stage_label(t_merge_str) == "Conflicts - needs a rebase"
    end

    test "stage_label and get_field handle struct, string keys, and invalid atoms", %{task: _task} do
      # Struct task
      uri_task = %URI{scheme: "https", host: "example.com"}
      assert Formatters.stage_label(uri_task) == "Waiting on you"

      # String key map
      str_task = %{"stage" => "engineer", "run" => %Run{status: :running}}
      assert Formatters.stage_label(str_task) == "Engineer running"

      # Valid string stage that converts to atom
      str_stage_task = %{stage: "engineer", run: %Run{status: :running}}
      assert Formatters.stage_label(str_stage_task) == "Engineer running"

      # A stage Rail does not recognise names nothing it can label.
      bad_task = %{stage: "totally_unknown_stage_string_xyz", run: %Run{status: :running}}
      assert Formatters.stage_label(bad_task) == "Waiting on you"

      non_atom_task = %{stage: 999, run: %Run{status: :running}}
      assert Formatters.stage_label(non_atom_task) == "Waiting on you"

      # Nil and non-map task
      assert Formatters.stage_label(nil) == "Waiting on you"
      assert Formatters.stage_label(12_345) == "Waiting on you"
    end
  end

  describe "stage_state_icon/1" do
    test "picks an icon from what the run for the stage is doing" do
      assert Formatters.stage_state_icon(%{stage: :engineer, run: %Run{status: :running}}) == "pi-play-circle"
      assert Formatters.stage_state_icon(%{stage: :engineer}) == "pi-clock"

      assert Formatters.stage_state_icon(%{stage: :engineer, run: %Run{status: :blocked_on_input}}) == "pi-question"

      assert Formatters.stage_state_icon(%{stage: :engineer, run: %Run{status: :finished, error: "boom"}}) ==
               "pi-warning-circle"

      assert Formatters.stage_state_icon(%{stage: :engineer, run: %Run{status: :finished}}) == "pi-pause-circle"
    end

    test "a stage that is done asks for a decision, and the merge asks for a merge" do
      done = %Run{status: :finished, stage_outcome: :done}

      assert Formatters.stage_state_icon(%{stage: :engineer, run: done}) == "pi-chat-text"
      assert Formatters.stage_state_icon(%{stage: :ready_to_merge, run: done}) == "pi-git-merge"
    end

    test "a conflicted branch shows the branch icon instead" do
      assert Formatters.stage_state_icon(%{stage: :engineer, has_merge_conflicts: true, is_rebasing: false}) ==
               "pi-git-branch"
    end
  end

  describe "stage_state_color/1 and stage_state_color_class/2" do
    test "colors a task by what the run for its stage is doing" do
      assert Formatters.stage_state_color(%{stage: :engineer, run: %Run{status: :running}}) == :primary

      assert Formatters.stage_state_color(%{stage: :engineer, run: %Run{status: :blocked_on_input}}) == :amber

      assert Formatters.stage_state_color(%{stage: :engineer, run: %Run{status: :finished, stage_outcome: :done}}) ==
               :amber

      assert Formatters.stage_state_color(%{stage: :engineer, run: %Run{status: :finished, error: "boom"}}) == :error
      assert Formatters.stage_state_color(%{stage: :engineer, run: %Run{status: :finished}}) == :outline
      assert Formatters.stage_state_color(%{stage: :engineer}) == :outline
    end

    test "a conflicted branch is amber whatever its run says" do
      assert Formatters.stage_state_color(%{stage: :engineer, has_merge_conflicts: true, is_rebasing: false}) == :amber
    end

    test "maps each color to text and chip classes" do
      running = %{stage: :engineer, run: %Run{status: :running}}
      failed = %{stage: :engineer, run: %Run{status: :finished, error: "boom"}}

      assert Formatters.stage_state_color_class(running) =~ "text-blue-600"
      assert Formatters.stage_state_color_class(running, :chip) =~ "bg-blue-100"
      assert Formatters.stage_state_color_class(failed) =~ "text-red-600"
      assert Formatters.stage_state_color_class(failed, :chip) =~ "bg-red-100"
      assert Formatters.stage_state_color_class(%{stage: :engineer}) =~ "text-slate-500"
      assert Formatters.stage_state_color_class(%{stage: :engineer}, :chip) =~ "bg-slate-100"

      blocked = %{stage: :engineer, run: %Run{status: :blocked_on_input}}
      assert Formatters.stage_state_color_class(blocked) =~ "text-amber-700"
      assert Formatters.stage_state_color_class(blocked, :chip) =~ "bg-amber-100"
    end
  end

  describe "shows_as_conflicted?/1 and has_merge_conflicts?/1" do
    test "a conflicted branch only shows as conflicted once nothing is running on it" do
      running = %{has_merge_conflicts: true, is_rebasing: false, run: %Run{status: :running}}
      refute Formatters.shows_as_conflicted?(running)

      stopped = %{has_merge_conflicts: true, is_rebasing: false, run: %Run{status: :finished}}
      assert Formatters.shows_as_conflicted?(stopped)

      never_run = %{has_merge_conflicts: true, is_rebasing: false}
      assert Formatters.shows_as_conflicted?(never_run)
    end

    test "a task already rebasing is not offered another rebase" do
      refute Formatters.shows_as_conflicted?(%{has_merge_conflicts: true, is_rebasing: true})
    end

    test "reads conflicts from mergeability as well as the explicit flag" do
      assert Formatters.has_merge_conflicts?(%{mergeability: :conflicting})
      assert Formatters.has_merge_conflicts?(%{has_merge_conflicts: true})
      refute Formatters.has_merge_conflicts?(%{mergeability: :clean})
      refute Formatters.has_merge_conflicts?(%{})
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
      assert Formatters.uses_design?(%{stage: :engineer, runs: [%{role_id: "designer"}]})
      assert Formatters.uses_design?(%{stage: :engineer, runs: [%{role: %{stage: :design}}]})
    end
  end

  describe "ticket_for/1 and plan_for/1" do
    test "ticket_for returns the description or fallback" do
      assert Formatters.ticket_for(%{description: "Build user auth"}) == "Build user auth"

      assert Formatters.ticket_for(%{description: "   "}) == "_No ticket body yet._"
      assert Formatters.ticket_for(nil) == "_No ticket body yet._"
    end

    test "plan_for returns the stored plan", %{task: task} do
      {:ok, task} = Pipeline.get_task(task.id)

      assert is_nil(Formatters.plan_for(task))

      %Plan{}
      |> Plan.changeset(%{content: "# Database Plan", captured_at: DateTime.utc_now()}, task.id)
      |> Repo.insert!()

      {:ok, _plan} = Pipeline.get_plan(task)
      assert Formatters.plan_for(task) == "# Database Plan"

      # Task with plans association loaded
      task_with_plans = %{plans: [%Plan{content: "# In-memory plan"}]}
      assert Formatters.plan_for(task_with_plans) == "# In-memory plan"

      # Empty plan returns nil
      assert is_nil(Formatters.plan_for(%{description: "Just a ticket"}))
    end

    test "rework ceiling computed from rework_budget_base + 5 or explicit rework_ceiling" do
      t_base = %{stage: :engineer, rework_cycles: 2, rework_budget_base: 3, run: %Run{status: :running}}
      assert Formatters.stage_label(t_base) == "Engineer running · rework 2 of 8"

      t_custom = %{stage: :engineer, rework_cycles: 1, rework_ceiling: 9, run: %Run{status: :running}}
      assert Formatters.stage_label(t_custom) == "Engineer running · rework 1 of 9"

      # stage_state_color_class with default 1-arg
      assert Formatters.stage_state_color_class(t_base) == "text-blue-600 dark:text-blue-500"

      # uses_design? with atom keys in map
      assert Formatters.uses_design?(%{stage: :engineer}, runs: %{design: true})
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
