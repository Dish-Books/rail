defmodule Rail.Issues.Schemas.IssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  test "valid changeset with valid attributes" do
    attrs = %{
      external_id: "lin_123",
      identifier: "ENG-101",
      title: "Fix crash on login",
      description: "Users crash when logging in",
      state: :in_progress,
      state_name: "In Progress",
      priority: :urgent,
      branch_name: "fix/login-crash",
      url: "https://linear.app/issue/ENG-101",
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
    assert errors[:external_id] == ["can't be blank"]
    assert errors[:identifier] == ["can't be blank"]
    assert errors[:title] == ["can't be blank"]
    assert errors[:state] == ["can't be blank"]
  end

  test "project_id is cast from attrs like any other field" do
    attrs = %{
      project_id: "prj_from_attrs",
      external_id: "lin_123_2",
      identifier: "ENG-101",
      title: "Fix crash on login",
      state: :triage
    }

    changeset = Issue.changeset(%Issue{}, attrs)
    assert changeset.valid?
    assert get_field(changeset, :project_id) == "prj_from_attrs"
  end

  test "persists to database with valid foreign key and enforces unique external_id" do
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
      external_id: "lin_unique_test_1",
      identifier: "ENG-201",
      title: "Database constraint test",
      state: :triage,
      project_id: project_id
    }

    changeset = Issue.changeset(%Issue{}, issue_attrs)

    assert {:ok, %Issue{id: "iss_" <> _id, project_id: ^project_id}} =
             Repo.insert(changeset)

    duplicate_changeset = Issue.changeset(%Issue{}, issue_attrs)
    assert {:error, failed_changeset} = Repo.insert(duplicate_changeset)
    assert errors_on(failed_changeset)[:external_id] == ["has already been taken"]
  end

  test "changeset validates enum types" do
    attrs = %{
      external_id: "lin_invalid_enums",
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
      assert Issue.states() == [:backlog, :triage, :todo, :in_progress, :in_review, :done, :canceled, :duplicate]
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
      assert Issue.state_label(:backlog) == "Backlog"
      assert Issue.state_label(:triage) == "Triage"
      assert Issue.state_label(:todo) == "Todo"
      assert Issue.state_label(:in_progress) == "In Progress"
      assert Issue.state_label(:in_review) == "In Review"
      assert Issue.state_label(:done) == "Done"
      assert Issue.state_label(:canceled) == "Canceled"
      assert Issue.state_label(:duplicate) == "Duplicate"
      assert is_nil(Issue.state_label(:invalid))
      assert is_nil(Issue.state_label(nil))
      assert is_nil(Issue.state_label(123))
    end

    test "finished_state?/1, finished?/1, and closed?/1 identify terminal states" do
      assert Issue.finished_states() == [:done, :canceled, :duplicate]
      assert Issue.finished_state?(:done)
      assert Issue.finished_state?(:canceled)
      assert Issue.finished_state?(:duplicate)
      refute Issue.finished_state?(:in_progress)
      refute Issue.finished_state?(:triage)
      refute Issue.finished_state?(:invalid)
      refute Issue.finished_state?(nil)
      refute Issue.finished_state?("done")
      refute Issue.finished_state?(123)

      assert Issue.finished?(:done)
      assert Issue.closed?(:canceled)
      refute Issue.finished?(:todo)
      refute Issue.closed?(:todo)
    end

    test "active?/1 identifies non-terminal working states" do
      for state <- [:triage, :backlog, :todo, :in_progress, :in_review] do
        assert Issue.active?(state)
      end

      refute Issue.active?(:done)
      refute Issue.active?(:canceled)
      refute Issue.active?(:duplicate)
      refute Issue.active?(:invalid)
      refute Issue.active?(nil)
      refute Issue.active?("todo")
      refute Issue.active?(123)
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
    test "only the tracker's changeset takes the cycle and the parent, so a local edit queues no push Linear refuses" do
      attrs = %{cycle_external_id: "cyc_1", parent_external_id: "lin_parent"}

      assert %{changes: %{cycle_external_id: "cyc_1", parent_external_id: "lin_parent"}} =
               Issue.tracker_changeset(%Issue{}, attrs)

      assert %{changes: changes} = Issue.changeset(%Issue{}, attrs)
      refute Map.has_key?(changes, :cycle_external_id)
      refute Map.has_key?(changes, :parent_external_id)
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

    test "a parent's done count leaves out canceled and duplicate sub-issues" do
      children =
        for state <- [:done, :in_progress, :todo, :canceled, :duplicate, :done],
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

    test "groups follow Linear's statuses, started furthest along first, and Rail's label for any it does not list" do
      statuses = [
        %{name: "Backlog", type: "backlog", position: 0},
        %{name: "Ready for Dev", type: "unstarted", position: 1},
        %{name: "In Progress", type: "started", position: 2},
        %{name: "In Review", type: "started", position: 3},
        %{name: "Triage", type: "triage", position: -1},
        %{name: "Done", type: "completed", position: 4},
        %{name: "Canceled", type: "canceled", position: 5}
      ]

      issue = fn id, state, name, estimate ->
        %Issue{id: id, project_id: "prj_a", state: state, state_name: name, estimate: estimate, parent: nil}
      end

      issues = [
        issue.("iss_1", :backlog, "Backlog", 1),
        issue.("iss_2", :in_progress, "In Progress", nil),
        issue.("iss_3", :in_progress, "In Review", 3),
        issue.("iss_4", :backlog, "Ready for Dev", 2),
        issue.("iss_5", :todo, nil, 1),
        issue.("iss_6", :done, "Done", 5),
        issue.("iss_7", :triage, "Triage", 1)
      ]

      assert [
               %{label: "In Review", state: :in_review, count: 1, points: 3},
               %{label: "In Progress", state: :in_progress, count: 1, points: 2},
               %{label: "Ready for Dev", state: :backlog, count: 1, points: 2},
               %{label: "Backlog", state: :backlog, count: 1, points: 1},
               %{label: "Triage", state: :triage},
               %{label: "Done", state: :done},
               %{label: "Todo", state: :todo, count: 1}
             ] = Issue.calculate_status_groups(issues, statuses, 2)

      assert [%{label: "Canceled", state: :canceled}, %{label: "Paused", state: :backlog}] =
               Issue.calculate_status_groups(
                 [issue.("iss_8", :canceled, "Canceled", 1), issue.("iss_9", :backlog, "Paused", 1)],
                 [%{name: "Paused", type: "paused", position: 9}, %{name: "Canceled", type: "canceled", position: 5}],
                 0
               )
    end

    test "a dimmed copy adds nothing to a group, and each copy of a parent has its own key" do
      statuses = [%{name: "In Progress", type: "started", position: 1}, %{name: "Todo", type: "unstarted", position: 0}]
      parent = %Issue{id: "iss_p", project_id: "prj_a", state: :done, state_name: "Done", estimate: 8, parent: nil}

      started = %Issue{
        id: "iss_a",
        project_id: "prj_a",
        state: :in_progress,
        state_name: "In Progress",
        estimate: 1,
        parent: parent
      }

      waiting = %Issue{id: "iss_b", project_id: "prj_a", state: :backlog, state_name: "Todo", estimate: 2, parent: parent}

      assert [
               %{count: 1, points: 1, rows: [%{dimmed: true, key: "group-0-iss_p-above-iss_a"}]},
               %{count: 1, points: 2, rows: [%{dimmed: true, key: "group-1-iss_p-above-iss_b"}]}
             ] = Issue.calculate_status_groups([started, waiting], statuses, 0)
    end

    test "an In Progress issue under a status named In Review shows as In Review" do
      assert :in_review = Issue.calculate_shown_state(%Issue{state: :in_progress, state_name: "In Review"})
      assert :in_progress = Issue.calculate_shown_state(%Issue{state: :in_progress, state_name: "In Progress"})
      assert :in_progress = Issue.calculate_shown_state(%Issue{state: :in_progress, state_name: nil})
      assert :in_review = Issue.calculate_shown_state(%Issue{state: :in_review})
    end

    test "only unfinished blockers are open" do
      entries = for state <- [:todo, :done, :canceled, :duplicate, :in_progress], do: %{issue: %Issue{state: state}}

      assert [%{issue: %Issue{state: :todo}}, %{issue: %Issue{state: :in_progress}}] =
               Issue.calculate_open_blockers(entries)
    end
  end
end
