defmodule Rail.Learnings.Actions.ListLearningsTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Projects

  setup %{project: project} do
    {:ok, other} =
      Projects.create_project(system_scope(), %{
        name: "Other #{System.unique_integer([:positive])}",
        github_repo: "example/other",
        github_installation_id: 1,
        default_branch: "main",
        key: "OTH",
        clone_path: "/tmp/repos/other"
      })

    %{other: other, project_id: project.id}
  end

  test "a query ranks rules by cosine distance alone, ties broken by id", %{project: project, project_id: project_id} do
    stub_vertex(%{"factory" => vector([1.0, 0.0])})

    %{id: near_id} =
      learning(project, %{rule: "Build rows with builders", kind: :convention}, embedding: [0.9, 0.1])

    %{id: word_id} = learning(project, %{rule: "factory", kind: :convention}, embedding: [0.0, 1.0])
    tie_a = learning(project, %{rule: "Tie", kind: :convention}, embedding: [0.5, 0.5])
    tie_b = learning(project, %{rule: "Tie too", kind: :convention}, embedding: [0.5, 0.5])
    [first_tie, second_tie] = Enum.sort([tie_a.id, tie_b.id])

    assert {:ok,
            [%Learning{id: ^near_id, similarity: similarity}, %{id: ^first_tie}, %{id: ^second_tie}, %{id: ^word_id}]} =
             Learnings.list_learnings(project_id: project_id, query: "factory")

    assert similarity > 0.9
    assert_received {:embedded, "factory", "RETRIEVAL_QUERY"}
  end

  test "a rule with no embedding is never an answer to a query, but is listed without one", %{
    project: project,
    project_id: project_id
  } do
    stub_vertex()
    %{id: unembedded_id} = learning(project, %{rule: "Not embedded yet", kind: :convention})

    assert {:ok, []} = Learnings.list_learnings(project_id: project_id, query: "anything")
    assert {:ok, [%Learning{id: ^unembedded_id, similarity: nil}]} = Learnings.list_learnings(project_id: project_id)
    assert {:ok, [%Learning{id: ^unembedded_id}]} = Learnings.list_learnings(project_id: project_id, query: "   ")
  end

  test "a query that cannot be embedded is an error, never a text match", %{project: project, project_id: project_id} do
    learning(project, %{rule: "factory", kind: :convention}, embedding: [1.0])

    assert {:error, :goth_disabled} = Learnings.list_learnings(project_id: project_id, query: "factory")
  end

  test "each filter keeps only what it should", %{project: project, project_id: project_id} do
    now = DateTime.utc_now()
    old = DateTime.shift(now, day: -30)
    calibration = learning(project, %{rule: "Calibration", kind: :calibration, roles: [:review]}, activated_at: old)
    everyone = learning(project, %{rule: "Every role", kind: :decision}, auto: true, activated_at: old)
    globbed = learning(project, %{rule: "Web only", kind: :design, path_glob: "lib/rail_web/**"})
    provisional = learning(project, %{rule: "Provisional", kind: :convention}, status: :provisional, activated_at: old)

    ids = fn opts ->
      {:ok, learnings} = Learnings.list_learnings([project_id: project_id] ++ opts)
      learnings |> Enum.map(& &1.id) |> Enum.sort()
    end

    assert ids.(kind: :calibration) == [calibration.id]
    assert ids.(role: :review) == Enum.sort([calibration.id, everyone.id, globbed.id, provisional.id])
    assert ids.(role: :engineer) == Enum.sort([everyone.id, globbed.id, provisional.id])
    assert ids.(auto: true) == [everyone.id]
    assert ids.(activated_since: DateTime.shift(now, week: -1)) == [globbed.id]
    assert ids.(status: :provisional) == [provisional.id]
    assert ids.(statuses: [:active]) == Enum.sort([calibration.id, everyone.id, globbed.id])
    assert ids.(path: "lib/rail_web/live/x.ex", kind: :design) == [globbed.id]
    assert ids.(path: "lib/rail/x.ex", kind: :design) == []
    assert ids.(ids: [everyone.id]) == [everyone.id]
  end

  test "a glob's own underscores and percent signs are literal", %{project: project, project_id: project_id} do
    rule = learning(project, %{rule: "Live views", kind: :convention, path_glob: "lib/rail_web/live/?ssue*.ex"})

    assert {:ok, [_rule]} = Learnings.list_learnings(project_id: project_id, path: "lib/rail_web/live/issues_live.ex")
    assert {:ok, []} = Learnings.list_learnings(project_id: project_id, path: "lib/railXweb/live/issues_live.ex")
    assert rule.path_glob == "lib/rail_web/live/?ssue*.ex"
  end

  test "another project's rules never appear", %{project: project, other: other, project_id: project_id} do
    learning(other, %{rule: "Theirs", kind: :convention})
    %{id: mine_id} = learning(project, %{rule: "Mine", kind: :convention})

    assert {:ok, [%Learning{id: ^mine_id}]} = Learnings.list_learnings(project_id: project_id)
  end

  test "newest first by activation or retirement, with each card's figures and a project", %{
    project: project,
    project_id: project_id
  } do
    now = DateTime.utc_now()

    %{id: older_id} =
      learning(project, %{rule: "Older", kind: :convention}, activated_at: DateTime.shift(now, day: -2))

    %{id: retired_id} =
      learning(project, %{rule: "Retired", kind: :convention}, status: :retired, retired_at: now)

    assert {:ok,
            [
              %Learning{id: ^retired_id, run_count: 0, suppressed_count: 0, broken_count: 0, flagged: false},
              %Learning{id: ^older_id, project: %{id: ^project_id}}
            ]} = Learnings.list_learnings(project_id: project_id)
  end

  test "sources come newest first when asked for", %{project: project, project_id: project_id} do
    task = learnings_task(project, "LST-1")
    comment = %Rail.Pipeline.Schemas.DiffComment{id: "dcm_lst", path: "a.ex", line_text: "x", body: "Say why"}
    {:ok, [rule]} = Learnings.record_corrections(task, [comment])

    assert {:ok, [%Learning{observations: [%{source_kind: :diff_comment, task: %{issue: %{identifier: "LST-1"}}}]}]} =
             Learnings.list_learnings(project_id: project_id, ids: [rule.id], sources: true)
  end
end
