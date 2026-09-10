defmodule Rail.Issues.Schemas.IssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
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
      linear_updated_at: ~U[2026-09-01 11:00:00.000000Z]
    }

    changeset = Issue.changeset(%Issue{}, attrs, "prj_test_123")
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

  test "project_id in attrs is not castable" do
    attrs = %{
      project_id: "prj_untrusted",
      external_id: "lin_123",
      identifier: "ENG-101",
      title: "Fix crash on login",
      state: :triage
    }

    changeset = Issue.changeset(%Issue{}, attrs)
    refute changeset.valid?
    assert errors_on(changeset)[:project_id] == ["can't be blank"]
  end

  test "factory returns valid struct" do
    issue = Issue.factory()

    assert byte_size(issue.external_id) > 0
    assert byte_size(issue.identifier) > 0
    assert byte_size(issue.title) > 0
    assert issue.priority == :medium
    assert issue.state == :triage
    assert issue.state_name == "Triage"
    assert byte_size(issue.url) > 0
    assert %DateTime{} = issue.linear_created_at
  end

  test "persists to database with valid foreign key and enforces unique external_id" do
    %Project{id: project_id} = Repo.insert!(Project.factory())

    issue_attrs = %{
      external_id: "lin_unique_test_1",
      identifier: "ENG-201",
      title: "Database constraint test",
      state: :triage
    }

    changeset = Issue.changeset(%Issue{}, issue_attrs, project_id)

    assert {:ok, %Issue{id: "iss_" <> _id, project_id: ^project_id}} =
             Repo.insert(changeset)

    duplicate_changeset = Issue.changeset(%Issue{}, issue_attrs, project_id)
    assert {:error, failed_changeset} = Repo.insert(duplicate_changeset)
    assert errors_on(failed_changeset)[:external_id] == ["has already been taken"]
  end
end
