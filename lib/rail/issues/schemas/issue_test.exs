defmodule Rail.Issues.Schemas.IssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
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
      linear_created_at: ~U[2026-09-01 10:00:00.000000Z],
      linear_updated_at: ~U[2026-09-01 11:00:00.000000Z],
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
      external_id: "lin_123",
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
        linear_team_id: "team_issue_schema",
        linear_team_key: "ISS",
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
      assert Issue.states() == [:backlog, :triage, :todo, :in_progress, :in_review, :done, :canceled]
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
      assert is_nil(Issue.state_label(:invalid))
      assert is_nil(Issue.state_label(nil))
      assert is_nil(Issue.state_label(123))
    end

    test "finished_state?/1, finished?/1, and closed?/1 identify terminal states" do
      assert Issue.finished_state?(:done)
      assert Issue.finished_state?(:canceled)
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
      refute Issue.active?(:invalid)
      refute Issue.active?(nil)
      refute Issue.active?("todo")
      refute Issue.active?(123)
    end

    test "cast_priority/1 casts valid atoms and strings" do
      assert {:ok, :urgent} = Issue.cast_priority(:urgent)
      assert {:ok, :high} = Issue.cast_priority("high")
      assert {:ok, :medium} = Issue.cast_priority("medium")
      assert {:ok, :low} = Issue.cast_priority(:low)
      assert :error = Issue.cast_priority(:invalid)
      assert :error = Issue.cast_priority("invalid")
      assert :error = Issue.cast_priority(nil)
      assert :error = Issue.cast_priority(123)
    end

    test "cast_state/1 casts valid atoms, strings, and camelCase strings" do
      assert {:ok, :in_progress} = Issue.cast_state(:in_progress)
      assert {:ok, :in_progress} = Issue.cast_state("in_progress")
      assert {:ok, :in_progress} = Issue.cast_state("inProgress")
      assert {:ok, :triage} = Issue.cast_state("triage")
      assert {:ok, :done} = Issue.cast_state(:done)
      assert :error = Issue.cast_state(:invalid)
      assert :error = Issue.cast_state("invalid")
      assert :error = Issue.cast_state(nil)
      assert :error = Issue.cast_state(123)
    end
  end
end
