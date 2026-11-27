defmodule Rail.Issues.Schemas.IssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Issues.Schemas.TestingScenario
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  test "valid changeset with valid attributes" do
    attrs = %{
      identifier: "ENG-101",
      title: "Fix crash on login",
      description: "Users crash when logging in",
      state: :in_progress,
      priority: :urgent,
      branch_name: "fix/login-crash",
      url: "https://rail.example/issues/iss_101",
      project_id: "prj_test_123"
    }

    changeset = Issue.changeset(%Issue{}, attrs)
    assert changeset.valid?
    assert get_field(changeset, :project_id) == "prj_test_123"
    assert get_field(changeset, :state) == :in_progress
    assert get_field(changeset, :priority) == :urgent
  end

  test "validates required fields" do
    changeset = Issue.changeset(%Issue{}, %{})

    refute changeset.valid?
    errors = errors_on(changeset)

    assert errors[:project_id] == ["can't be blank"]
    # Postgres names an issue as it inserts it.
    refute Map.has_key?(errors, :identifier)
    assert errors[:title] == ["can't be blank"]
    assert errors[:state] == ["can't be blank"]
  end

  test "project_id is cast from attrs like any other field" do
    attrs = %{
      project_id: "prj_from_attrs",
      identifier: "ENG-101",
      title: "Fix crash on login",
      state: :todo
    }

    changeset = Issue.changeset(%Issue{}, attrs)
    assert changeset.valid?
    assert get_field(changeset, :project_id) == "prj_from_attrs"
  end

  test "persists to database with valid foreign key and enforces a number unique in its project" do
    {:ok, %Project{id: project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Issue Schema Project",
        github_repo: "org/issue-schema",
        github_installation_id: 5001,
        key: "ISS",
        default_branch: "main",
        clone_path: "/tmp/repos/issue-schema"
      })

    issue_attrs = %{
      identifier: "ENG-201",
      number: 201,
      title: "Database constraint test",
      state: :todo,
      project_id: project_id
    }

    changeset = Issue.changeset(%Issue{}, issue_attrs)

    assert {:ok, %Issue{id: "iss_" <> _id, project_id: ^project_id}} =
             Repo.insert(changeset)

    duplicate_changeset = Issue.changeset(%Issue{}, issue_attrs)
    assert {:error, failed_changeset} = Repo.insert(duplicate_changeset)
    assert errors_on(failed_changeset)[:number] == ["has already been taken"]
  end

  test "changeset validates enum types" do
    attrs = %{
      identifier: "ENG-999",
      title: "Invalid enums",
      priority: "invalid_priority",
      state: "invalid_state",
      project_id: "prj_123"
    }

    assert %{
             priority: ["is invalid"],
             state: ["is invalid"]
           } = errors_on(Issue.changeset(%Issue{}, attrs))
  end

  describe "enums, labels, and helper functions" do
    test "priorities/0 and states/0 return expected lists" do
      assert Issue.priorities() == [:urgent, :high, :medium, :low]
      assert Issue.states() == [:todo, :in_progress, :in_review, :done, :canceled]
    end

    test "priority_label/1 returns correct human readable labels" do
      assert Issue.priority_label(:urgent) == "Urgent"
      assert Issue.priority_label(:high) == "High"
      assert Issue.priority_label(:medium) == "Medium"
      assert Issue.priority_label(:low) == "Low"
      assert is_nil(Issue.priority_label(:invalid))
      assert is_nil(Issue.priority_label(nil))
      assert is_nil(Issue.priority_label(123))
    end

    test "state_label/1 returns correct human readable labels" do
      assert Issue.state_label(:todo) == "Todo"
      assert Issue.state_label(:in_progress) == "In Progress"
      assert Issue.state_label(:in_review) == "In Review"
      assert Issue.state_label(:done) == "Done"
      assert Issue.state_label(:canceled) == "Canceled"
      assert is_nil(Issue.state_label(:triage))
      assert is_nil(Issue.state_label(:backlog))
      assert is_nil(Issue.state_label(:duplicate))
      assert is_nil(Issue.state_label(:invalid))
      assert is_nil(Issue.state_label(nil))
      assert is_nil(Issue.state_label(123))
    end

    test "finished_state?/1, finished?/1, and closed?/1 identify terminal states" do
      assert Issue.finished_states() == [:done, :canceled]
      assert Issue.finished_state?(:done)
      assert Issue.finished_state?(:canceled)
      refute Issue.finished_state?(:in_progress)
      refute Issue.finished_state?(:todo)
      refute Issue.finished_state?(:invalid)
      refute Issue.finished_state?(nil)
      refute Issue.finished_state?("done")
      refute Issue.finished_state?(123)

      assert Issue.finished?(:done)
      assert Issue.closed?(:canceled)
      refute Issue.finished?(:todo)
      refute Issue.closed?(:todo)
    end

    test "started_state?/1 holds for the states work is under way in, and no other" do
      assert Issue.started_state?(:in_progress)
      assert Issue.started_state?(:in_review)

      for state <- [:todo, :done, :canceled, nil] do
        refute Issue.started_state?(state)
      end
    end

    test "active?/1 identifies non-terminal working states" do
      for state <- [:todo, :in_progress, :in_review] do
        assert Issue.active?(state)
      end

      refute Issue.active?(:done)
      refute Issue.active?(:canceled)
      refute Issue.active?(:invalid)
      refute Issue.active?(nil)
      refute Issue.active?("todo")
      refute Issue.active?(123)
    end
  end

  describe "testing" do
    test "a tester's change to the scenarios or the place moves a Waiting ticket to In testing, and the agent's does not" do
      waiting = %Issue{state: :done, testing_state: :waiting, testing_scenarios: []}
      scenario = TestingScenario.agent("Open the page")

      assert %Ecto.Changeset{changes: %{testing_state: :testing, testing_scenarios: [_one]}} =
               Issue.testing_scenarios_changeset(waiting, [scenario], :tester)

      assert %Ecto.Changeset{changes: %{testing_scenarios: [_one]} = by_agent} =
               Issue.testing_scenarios_changeset(waiting, [scenario], :agent)

      refute Map.has_key?(by_agent, :testing_state)

      assert %Ecto.Changeset{changes: %{testing_environment: :staging, testing_state: :testing}} =
               Issue.testing_place_changeset(waiting, %{"testing_environment" => "staging"})

      no_changes = %{}
      assert %Ecto.Changeset{changes: ^no_changes} = Issue.testing_place_changeset(waiting, %{})

      assert %Ecto.Changeset{changes: %{testing_platform: :ios} = testing} =
               Issue.testing_place_changeset(%{waiting | testing_state: :testing}, %{testing_platform: "ios"})

      refute Map.has_key?(testing, :testing_state)
    end

    test "Where I tested takes Production or Staging, a platform and a device of at most 200 characters" do
      issue = %Issue{state: :done, testing_state: :testing}

      assert ["Production", "Staging"] = Enum.map(Issue.testing_environments(), &Issue.testing_environment_label/1)
      assert ["Web", "Android", "iOS"] = Enum.map(Issue.testing_platforms(), &Issue.testing_platform_label/1)

      refute Issue.testing_place_changeset(issue, %{testing_environment: "preview"}).valid?
      refute Issue.testing_place_changeset(issue, %{testing_device: String.duplicate("a", 201)}).valid?
      assert Issue.testing_place_changeset(issue, %{testing_device: String.duplicate("a", 200)}).valid?
    end

    test "a ticket stamped an hour ago is being written, one stamped two hours ago or never is not" do
      now = DateTime.utc_now()
      hour_ago = DateTime.shift(now, hour: -1)
      two_hours_ago = DateTime.shift(now, hour: -2)

      assert Issue.writing_scenarios?(%Issue{scenarios_requested_at: hour_ago})
      refute Issue.writing_scenarios?(%Issue{scenarios_requested_at: two_hours_ago})
      refute Issue.writing_scenarios?(%Issue{scenarios_requested_at: nil})

      assert Issue.calculate_writing_deadline(%Issue{scenarios_requested_at: hour_ago}) ==
               DateTime.shift(hour_ago, hour: 2)

      assert Issue.calculate_writing_deadline(%Issue{}) == nil
      assert Issue.calculate_claim_cutoff(now) == DateTime.shift(now, hour: -1)
    end

    test "the stamp is kept to the second, and the agent's result clears both stamps" do
      at = ~U[2026-11-27 10:00:00.123456Z]

      assert %Ecto.Changeset{changes: %{scenarios_requested_at: ~U[2026-11-27 10:00:00Z]}} =
               Issue.scenarios_requested_changeset(%Issue{}, at)

      stamped = %Issue{
        testing_state: :waiting,
        testing_scenarios: [],
        scenarios_requested_at: ~U[2026-11-27 10:00:00Z],
        scenarios_started_at: ~U[2026-11-27 10:01:00Z]
      }

      assert %Ecto.Changeset{
               changes: %{scenarios_requested_at: nil, scenarios_started_at: nil, testing_scenarios: [_one]} = changes
             } = Issue.scenarios_written_changeset(stamped, [TestingScenario.agent("Check it")])

      refute Map.has_key?(changes, :testing_state)
    end

    test "Mark tested requires a trimmed reason only when there are no scenarios" do
      empty = %Issue{state: :done, testing_state: :testing, testing_scenarios: []}

      refute Issue.tested_changeset(empty, %{}).valid?

      assert %{no_scenarios_reason: ["Write why there was nothing to test."]} =
               errors_on(Issue.tested_changeset(empty, %{}))

      refute Issue.tested_changeset(empty, %{"no_scenarios_reason" => "   "}).valid?
      refute Issue.tested_changeset(empty, %{"no_scenarios_reason" => String.duplicate("a", 1_001)}).valid?

      assert %Ecto.Changeset{valid?: true, changes: %{testing_state: :tested, no_scenarios_reason: "Only docs"}} =
               Issue.tested_changeset(empty, %{"no_scenarios_reason" => "  Only docs \n"})

      passed = %{TestingScenario.agent("Open it") | result: :passed}
      with_scenarios = %{empty | testing_scenarios: [passed], no_scenarios_reason: "Stale"}

      assert %Ecto.Changeset{valid?: true, changes: %{testing_state: :tested, no_scenarios_reason: nil}} =
               Issue.tested_changeset(with_scenarios, %{"no_scenarios_reason" => "Ignored"})
    end

    test "Mark tested needs every scenario Passed and Send to triage one Failed, counted as passed, failed and open" do
      [passed, failed, open] =
        for result <- [:passed, :failed, nil], do: %{TestingScenario.agent("Check") | result: result}

      assert Issue.can_mark_tested?(%Issue{testing_scenarios: []})
      assert Issue.can_mark_tested?(%Issue{testing_scenarios: [passed]})
      refute Issue.can_mark_tested?(%Issue{testing_scenarios: [passed, open]})
      refute Issue.can_mark_tested?(%Issue{testing_scenarios: [passed, failed]})

      refute Issue.can_send_to_triage?(%Issue{testing_scenarios: []})
      refute Issue.can_send_to_triage?(%Issue{testing_scenarios: [passed, open]})
      assert Issue.can_send_to_triage?(%Issue{testing_scenarios: [failed, open]})

      assert %{passed: 1, failed: 1, open: 2} =
               Issue.calculate_testing_progress(%Issue{testing_scenarios: [passed, failed, open, open]})
    end

    test "a ticket is in the queue only in Done and Waiting or In testing, each state with its label" do
      assert Issue.in_testing_queue?(%Issue{state: :done, testing_state: :waiting})
      assert Issue.in_testing_queue?(%Issue{state: :done, testing_state: :testing})
      refute Issue.in_testing_queue?(%Issue{state: :done, testing_state: :tested})
      refute Issue.in_testing_queue?(%Issue{state: :canceled, testing_state: :waiting})

      assert ["Waiting", "In testing", "Tested", "Sent to triage"] =
               Enum.map(Issue.testing_states(), &Issue.testing_label/1)
    end

    test "a ticket cannot be left with no testing state", %{project: project} do
      issue =
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          identifier: "NT-1",
          title: "Done",
          state: :done
        })
        |> Repo.insert!()

      assert_raise Postgrex.Error, ~r/not_null_violation/, fn ->
        issue |> Ecto.Changeset.change(testing_state: nil) |> Repo.update!()
      end
    end
  end

  test "an issue with no skipped steps runs every step, with Plan, Engineer and Review as its stages" do
    issue = %Issue{}

    assert Issue.optional_steps() == [:product, :design, :architect, :demo]
    refute Enum.any?(Issue.optional_steps(), &Issue.skips_step?(issue, &1))
    assert Issue.calculate_stages(issue) == [:plan, :engineer, :review]
  end

  test "an issue with Product, Design and Architect off runs Engineer and Review only" do
    assert Issue.calculate_stages(%Issue{skipped_steps: [:product, :design, :architect]}) == [:engineer, :review]
    assert Issue.calculate_stages(%Issue{skipped_steps: [:product, :design, :demo]}) == [:plan, :engineer, :review]
    assert Issue.skips_step?(%Issue{skipped_steps: [:demo]}, :demo)
  end

  test "step_label/1 names each step as a sentence says it" do
    assert Enum.map(Issue.optional_steps(), &Issue.step_label/1) == ["product", "design", "architect", "demo"]
  end

  test "an issue with no stages runs the built-ins, and one with stages runs them in order" do
    assert Issue.calculate_next_stage(%Issue{}, :plan) == :engineer
    assert Issue.calculate_next_stage(%Issue{}, :review) == nil

    issue = %Issue{
      stages: [
        %IssueStage{stage: :custom, name: "Missing strings", prompt: "Find them."},
        %IssueStage{stage: :plan},
        %IssueStage{stage: :engineer},
        %IssueStage{stage: :custom, name: "License check", prompt: "Check them."},
        %IssueStage{stage: :review}
      ]
    }

    assert Issue.calculate_stages(issue) == [
             {:custom, "Missing strings"},
             :plan,
             :engineer,
             {:custom, "License check"},
             :review
           ]

    assert Issue.calculate_next_stage(issue, {:custom, "Missing strings"}) == :plan
    assert Issue.calculate_next_stage(issue, :engineer) == {:custom, "License check"}
    assert Issue.calculate_next_stage(issue, {:custom, "License check"}) == :review
    assert %IssueStage{prompt: "Check them."} = Issue.custom_stage(issue, "License check")
    assert Issue.custom_stage(issue, "Nothing") == nil

    assert Issue.calculate_stages(%{issue | skipped_steps: [:product, :design, :architect]}) == [
             {:custom, "Missing strings"},
             :engineer,
             {:custom, "License check"},
             :review
           ]
  end

  describe "cycles and parents" do
    test "only tracker_changeset takes the cycle and the parent, which Rail sets through it" do
      attrs = %{cycle_id: "cyc_1", parent_id: "iss_parent"}

      assert %{changes: %{cycle_id: "cyc_1", parent_id: "iss_parent"}} =
               Issue.tracker_changeset(%Issue{}, attrs)

      assert %{changes: changes} = Issue.changeset(%Issue{}, attrs)
      refute Map.has_key?(changes, :cycle_id)
      refute Map.has_key?(changes, :parent_id)
    end

    test "a parent and sub-issues count only in the issue's own project" do
      parent = %Issue{id: "iss_p", project_id: "prj_a"}
      elsewhere = %Issue{id: "iss_x", project_id: "prj_b"}

      assert %Issue{id: "iss_p"} = Issue.calculate_parent(%Issue{project_id: "prj_a", parent: parent})
      assert nil == Issue.calculate_parent(%Issue{project_id: "prj_a", parent: elsewhere})
      assert nil == Issue.calculate_parent(%Issue{project_id: "prj_a"})

      assert [%Issue{id: "iss_p"}] =
               Issue.calculate_children(%Issue{project_id: "prj_a", children: [parent, elsewhere]})

      assert [] = Issue.calculate_children(%Issue{project_id: "prj_a"})
    end

    test "a parent's done count leaves out canceled sub-issues" do
      children =
        for state <- [:done, :in_progress, :todo, :canceled, :canceled, :done],
            do: %Issue{project_id: "prj_a", state: state}

      assert {2, 4} = Issue.calculate_sub_issue_count(%Issue{project_id: "prj_a", children: children})
      assert {0, 0} = Issue.calculate_sub_issue_count(%Issue{project_id: "prj_a", children: []})
    end

    test "a sub-issue nests under its parent's row, or under a dimmed copy when the parent is not a top-level row" do
      grandparent = %Issue{id: "iss_g", project_id: "prj_a", parent: nil}
      parent = %Issue{id: "iss_p", project_id: "prj_a", parent: nil}
      child = %Issue{id: "iss_c", project_id: "prj_a", parent: parent}
      apart = %Issue{id: "iss_s", project_id: "prj_a", parent: grandparent}
      foreign = %Issue{id: "iss_f", project_id: "prj_a", parent: %Issue{id: "iss_o", project_id: "prj_b"}}
      middle = %Issue{id: "iss_m", project_id: "prj_a", parent: grandparent}
      grandchild = %Issue{id: "iss_gc", project_id: "prj_a", parent: middle}

      # The child comes first, newest first, so its tree takes the child's place.
      assert [
               %{issue: %Issue{id: "iss_p"}, key: "iss_p", dimmed: false, sub_issues: [%{issue: %Issue{id: "iss_c"}}]},
               %{issue: %Issue{id: "iss_g"}, key: "iss_g-above-iss_s", dimmed: true, sub_issues: [_apart, _middle]},
               %{issue: %Issue{id: "iss_f"}, dimmed: false, sub_issues: []},
               %{issue: %Issue{id: "iss_m"}, key: "iss_m-above-iss_gc", dimmed: true, sub_issues: [_grandchild]}
             ] = Issue.calculate_issue_tree([child, parent, apart, foreign, middle, grandchild])
    end

    test "groups follow the statuses given, started furthest along first, and Rail's label for any they do not list" do
      statuses = [
        %{name: "Backlog", type: "backlog", position: 0},
        %{name: "Ready for Dev", type: "unstarted", position: 1},
        %{name: "In Progress", type: "started", position: 2},
        %{name: "In Review", type: "started", position: 3},
        %{name: "Todo", type: "triage", position: -1},
        %{name: "Done", type: "completed", position: 4},
        %{name: "Canceled", type: "canceled", position: 5}
      ]

      issue = fn id, state, estimate ->
        %Issue{id: id, project_id: "prj_a", state: state, estimate: estimate, parent: nil}
      end

      issues = [
        issue.("iss_2", :in_progress, nil),
        issue.("iss_3", :in_review, 3),
        issue.("iss_5", :todo, 1),
        issue.("iss_6", :done, 5)
      ]

      # Backlog and Ready for Dev hold no issue, so they have no group; a Triage kind shows Todo's icon.
      assert [
               %{label: "In Review", state: :in_review, count: 1, points: 3},
               %{label: "In Progress", state: :in_progress, count: 1, points: 2},
               %{label: "Todo", state: :todo, count: 1, points: 1},
               %{label: "Done", state: :done}
             ] = Issue.calculate_status_groups(issues, statuses, %{"prj_a" => 2})

      assert [%{label: "Canceled", state: :canceled}, %{label: "Todo", state: :todo}] =
               Issue.calculate_status_groups(
                 [issue.("iss_8", :canceled, 1), issue.("iss_9", :todo, 1)],
                 [%{name: "Paused", type: "paused", position: 9}, %{name: "Canceled", type: "canceled", position: 5}],
                 %{"prj_a" => 0}
               )
    end

    test "Rail's statuses group In Review first and Canceled last, issues in one state sharing its group",
         %{project: project} do
      {:ok, %{statuses: statuses}} = Issues.get_cycles(project)

      issues =
        for {state, n} <- Enum.with_index([:done, :canceled, :todo, :todo, :in_progress, :in_review]),
            do: %Issue{id: "iss_#{n}", project_id: "prj_a", state: state, parent: nil}

      assert [
               %{label: "In Review", state: :in_review, count: 1},
               %{label: "In Progress", state: :in_progress, count: 1},
               %{label: "Todo", state: :todo, count: 2, points: 2},
               %{label: "Done", state: :done},
               %{label: "Canceled", state: :canceled}
             ] = Issue.calculate_status_groups(issues, statuses, %{"prj_a" => 1})
    end

    test "an issue its cycle closed In Progress and since finished groups as In Progress, its row live", %{
      project: project
    } do
      {:ok, %{statuses: statuses}} = Issues.get_cycles(project)

      issue = %Issue{
        id: "iss_rolled",
        project_id: "prj_a",
        state: :done,
        estimate: 3,
        cycle_state: :in_progress,
        parent: nil
      }

      for statuses <- [statuses, []] do
        assert [
                 %{
                   label: "In Progress",
                   state: :in_progress,
                   count: 1,
                   points: 3,
                   rows: [%{issue: %Issue{id: "iss_rolled", state: :done}}]
                 }
               ] = Issue.calculate_status_groups([issue], statuses, %{"prj_a" => 1})
      end
    end

    test "an unestimated issue in a group counts its own project's default estimate" do
      statuses = [%{name: "In Progress", type: "started", position: 1}]

      issues = [
        %Issue{id: "iss_a", project_id: "prj_a", state: :in_progress, parent: nil},
        %Issue{id: "iss_b", project_id: "prj_b", state: :in_progress, parent: nil},
        %Issue{id: "iss_c", project_id: "prj_b", state: :in_progress, estimate: 5, parent: nil}
      ]

      assert [%{label: "In Progress", count: 3, points: 9}] =
               Issue.calculate_status_groups(issues, statuses, %{"prj_a" => 1, "prj_b" => 3})
    end

    test "a dimmed copy adds nothing to a group, and each copy of a parent has its own key" do
      statuses = [%{name: "In Progress", type: "started", position: 1}, %{name: "Todo", type: "unstarted", position: 0}]
      parent = %Issue{id: "iss_p", project_id: "prj_a", state: :done, estimate: 8, parent: nil}
      started = %Issue{id: "iss_a", project_id: "prj_a", state: :in_progress, estimate: 1, parent: parent}
      waiting = %Issue{id: "iss_b", project_id: "prj_a", state: :todo, estimate: 2, parent: parent}

      assert [
               %{count: 1, points: 1, rows: [%{dimmed: true, key: "group-0-iss_p-above-iss_a"}]},
               %{count: 1, points: 2, rows: [%{dimmed: true, key: "group-1-iss_p-above-iss_b"}]}
             ] = Issue.calculate_status_groups([started, waiting], statuses, %{"prj_a" => 0})
    end

    test "an issue's status icon shows its own state" do
      assert :in_progress = Issue.calculate_shown_state(%Issue{state: :in_progress})
      assert :in_review = Issue.calculate_shown_state(%Issue{state: :in_review})
    end

    test "calculate_status_name/1 is Rail's label for the issue's state" do
      assert "In Progress" = Issue.calculate_status_name(%Issue{state: :in_progress})
      assert "Todo" = Issue.calculate_status_name(%Issue{state: :todo})
    end

    test "only unfinished blockers are open" do
      entries = for state <- [:todo, :done, :canceled, :in_progress], do: %{issue: %Issue{state: state}}

      assert [%{issue: %Issue{state: :todo}}, %{issue: %Issue{state: :in_progress}}] =
               Issue.calculate_open_blockers(entries)
    end
  end
end
