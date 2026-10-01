defmodule Rail.Pipeline.Actions.ListReviewFindingsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_lsf_1", "identifier" => "LSF-1", "title" => "List Findings"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "List Findings"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "worst first, whatever order they were raised in", %{task: task} do
    {:ok, _synced} =
      Pipeline.sync_review_findings(task, [
        %{key: "a-nit", title: "A nit", severity: :nit, recommendation: :skip, status: :open},
        %{key: "a-blocker", title: "A blocker", severity: :blocker, recommendation: :fix, status: :open},
        %{key: "a-minor", title: "A minor", severity: :minor, recommendation: :fix, status: :open},
        %{key: "a-major", title: "A major", severity: :major, recommendation: :fix, status: :open}
      ])

    assert ["a-blocker", "a-major", "a-minor", "a-nit"] =
             task |> Pipeline.list_review_findings() |> Enum.map(& &1.key)
  end

  # Where a finding sits is what it is, so ruling on it never loses the reader's place.
  test "a ruling moves nothing", %{task: task} do
    {:ok, [blocker, major, _nit]} =
      Pipeline.sync_review_findings(task, [
        %{key: "a-blocker", title: "A blocker", severity: :blocker, recommendation: :fix, status: :open},
        %{key: "a-major", title: "A major", severity: :major, recommendation: :fix, status: :open},
        %{key: "a-nit", title: "A nit", severity: :nit, recommendation: :fix, status: :open}
      ])

    {:ok, _dismissed} = Pipeline.decide_review_finding(blocker, :skip)
    {:ok, _decided} = Pipeline.decide_review_finding(major, :fix)

    assert ["a-blocker", "a-major", "a-nit"] =
             task |> Pipeline.list_review_findings() |> Enum.map(& &1.key)
  end

  test "a fixed finding stays where its severity puts it", %{task: task} do
    {:ok, _synced} =
      Pipeline.sync_review_findings(task, [
        %{key: "a-blocker", title: "A blocker", severity: :blocker, recommendation: :fix, status: :fixed},
        %{key: "a-nit", title: "A nit", severity: :nit, recommendation: :fix, status: :open}
      ])

    assert ["a-blocker", "a-nit"] = task |> Pipeline.list_review_findings() |> Enum.map(& &1.key)
  end

  test "findings of one severity keep the order they were raised in, however a later pass lists them", %{
    task: task
  } do
    raised =
      for key <- ["a", "b", "c"] do
        %{key: key, title: key, severity: :nit, recommendation: :fix, status: :open}
      end

    {:ok, _first_pass} = Pipeline.sync_review_findings(task, raised)

    assert ["a", "b", "c"] = task |> Pipeline.list_review_findings() |> Enum.map(& &1.key)

    {:ok, _second_pass} = Pipeline.sync_review_findings(task, Enum.reverse(raised))

    assert ["a", "b", "c"] = task |> Pipeline.list_review_findings() |> Enum.map(& &1.key)
  end

  test "a tie on when they were raised is broken the same way every time", %{task: task} do
    {:ok, synced} =
      Pipeline.sync_review_findings(task, [
        %{key: "a", title: "a", severity: :nit, recommendation: :fix, status: :open},
        %{key: "b", title: "b", severity: :nit, recommendation: :fix, status: :open}
      ])

    # No factory builds findings, so the tie is arranged on the rows sync wrote.
    {2, nil} =
      Repo.update_all(from(f in ReviewFinding, where: f.task_id == ^task.id),
        set: [inserted_at: ~U[2026-01-01 00:00:00.000000Z]]
      )

    by_id = synced |> Enum.sort_by(& &1.id) |> Enum.map(& &1.key)

    assert ^by_id = task |> Pipeline.list_review_findings() |> Enum.map(& &1.key)
    assert ^by_id = task |> Pipeline.list_review_findings() |> Enum.map(& &1.key)
  end

  test "a task nobody has reviewed has no findings", %{task: task} do
    assert Pipeline.list_review_findings(task) == []
  end
end
