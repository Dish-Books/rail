defmodule Rail.Pipeline.Schemas.ReviewFindingTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Projects

  setup do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Review Finding Schema Project",
        github_repo: "org/review-finding-schema",
        github_installation_id: 47_028,
        linear_workspace: %{
          name: "Review Finding Workspace",
          external_id: "lin_ws_review_finding",
          token: "lin_api_token_review_finding",
          webhook_secret: "whsec_review_finding"
        },
        linear_team_key: "RVF",
        default_branch: "main",
        clone_path: "/tmp/repos/review-finding-schema",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_rvf_1", "identifier" => "RVF-1", "title" => "Review Finding"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Review Finding"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    attrs = %{
      task_id: task.id,
      key: "unhandled-nil",
      title: "Nil is not handled",
      severity: :major,
      recommendation: :fix,
      status: :open
    }

    %{task: task, attrs: attrs}
  end

  # Seeding the decision from the recommendation made the two indistinguishable
  # afterwards: a finding the reviewer thought not worth fixing read exactly like
  # one a person had dismissed.
  test "a finding nobody has ruled on has no decision", %{attrs: attrs} do
    changeset = ReviewFinding.changeset(%ReviewFinding{}, attrs)

    assert changeset.valid?
    refute Map.has_key?(changeset.changes, :decision)
  end

  test "the reviewer cannot write the decision", %{attrs: attrs} do
    changeset = ReviewFinding.changeset(%ReviewFinding{}, Map.put(attrs, :decision, :skip))

    refute Map.has_key?(changeset.changes, :decision)
  end

  test "a finding needs a key, a title, a severity and a recommendation", %{task: task} do
    changeset = ReviewFinding.changeset(%ReviewFinding{}, %{task_id: task.id})

    refute changeset.valid?
    assert %{key: ["can't be blank"], title: ["can't be blank"]} = errors_on(changeset)
    assert %{severity: ["can't be blank"], recommendation: ["can't be blank"]} = errors_on(changeset)
  end

  test "one key per task", %{attrs: attrs} do
    %ReviewFinding{} |> ReviewFinding.changeset(attrs) |> Repo.insert!()

    assert {:error, changeset} = %ReviewFinding{} |> ReviewFinding.changeset(attrs) |> Repo.insert()
    assert %{task_id: ["has already been taken"]} = errors_on(changeset)
  end

  test "the human's call is the only thing the decision changeset writes", %{attrs: attrs} do
    finding = %ReviewFinding{} |> ReviewFinding.changeset(attrs) |> Repo.insert!()
    assert finding.decision == nil

    assert %{decision: :skip} = finding |> ReviewFinding.decision_changeset(:skip) |> Repo.update!()
  end

  test "outstanding is only what a human said to fix", %{attrs: attrs} do
    finding = %ReviewFinding{} |> ReviewFinding.changeset(attrs) |> Repo.insert!()

    refute ReviewFinding.outstanding?(finding)
    assert ReviewFinding.outstanding?(%{finding | decision: :fix})
    refute ReviewFinding.outstanding?(%{finding | decision: :skip})
    refute ReviewFinding.outstanding?(%{finding | decision: :fix, status: :fixed})
  end

  test "undecided is what is still waiting on a human", %{attrs: attrs} do
    finding = %ReviewFinding{} |> ReviewFinding.changeset(attrs) |> Repo.insert!()

    assert ReviewFinding.undecided?(finding)
    refute ReviewFinding.undecided?(%{finding | decision: :skip})
    refute ReviewFinding.undecided?(%{finding | status: :fixed})
  end

  test "state is the one word a reader groups by", %{attrs: attrs} do
    finding = %ReviewFinding{} |> ReviewFinding.changeset(attrs) |> Repo.insert!()

    assert ReviewFinding.state(finding) == :undecided
    assert ReviewFinding.state(%{finding | decision: :fix}) == :to_fix
    assert ReviewFinding.state(%{finding | decision: :fix, status: :not_fixed}) == :not_fixed
    assert ReviewFinding.state(%{finding | status: :fixed}) == :fixed
    assert ReviewFinding.state(%{finding | decision: :skip}) == :dismissed
  end

  test "severities read as words" do
    assert Enum.map(ReviewFinding.severities(), &ReviewFinding.severity_label/1) ==
             ["Blocker", "Major", "Minor", "Nit"]
  end
end
