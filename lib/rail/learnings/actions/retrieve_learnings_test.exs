defmodule Rail.Learnings.Actions.RetrieveLearningsTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningRetrieval
  alias Rail.Pipeline
  alias Rail.Roles

  setup %{project: project} do
    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    task = learnings_task(project, "RET-1")

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: engineer.id, status: :starting, started_at: DateTime.utc_now()})

    %{run: run, engineer: engineer, task: task}
  end

  test "only active and provisional rules for the role are given, nearest first", %{project: project, run: run} do
    stub_vertex(%{"ticket" => vector([1.0])})
    %{id: active_id} = learning(project, %{rule: "Active", kind: :convention}, embedding: [1.0])

    %{id: provisional_id} =
      learning(project, %{rule: "Provisional", kind: :convention}, status: :provisional, embedding: [0.8, 0.2])

    learning(project, %{rule: "Retired", kind: :convention}, status: :retired, embedding: [1.0])
    learning(project, %{rule: "Draft", kind: :convention}, status: :proposed, embedding: [1.0])
    learning(project, %{rule: "Reviewer only", kind: :convention, roles: [:review]}, embedding: [1.0])

    assert [%Learning{id: ^active_id}, %Learning{id: ^provisional_id}] = Learnings.retrieve_learnings(run, ["the ticket"])
    assert_received {:embedded, "the ticket", "RETRIEVAL_QUERY"}
  end

  test "a path-scoped rule is found only for files under its glob", %{project: project, run: run} do
    stub_vertex(%{"lib/" => vector([1.0])})

    %{id: web_id} =
      learning(project, %{rule: "Web", kind: :convention, path_glob: "lib/rail_web/**"}, embedding: [1.0])

    assert [%Learning{id: ^web_id}] = Learnings.retrieve_learnings(run, [{"lib/rail_web/live/a.ex", "+ code"}])
    assert_received {:embedded, "lib/rail_web/live/a.ex\n+ code", "CODE_RETRIEVAL_QUERY"}
    assert [] = Learnings.retrieve_learnings(run, [{"lib/rail/a.ex", "+ code"}, {"lib/empty.ex", "  "}])
  end

  test "each query gives its nearest 20, pinned rules are always added, and the ranked ones stop at 25", %{
    project: project,
    run: run
  } do
    one_hot = fn n -> Enum.reverse([1.0 | List.duplicate(0.0, n)]) end
    stub_vertex(Map.new(1..30, &{"<q#{&1}>", vector(one_hot.(&1))}))
    for n <- 1..30, do: learning(project, %{rule: "Rule #{n}", kind: :convention}, embedding: one_hot.(n))
    pinned = learning(project, %{rule: "Pinned", kind: :environment, pinned: true})

    assert [%Learning{rule: "Rule 1"} | _rest] = given = Learnings.retrieve_learnings(run, ["<q1>"])
    assert length(given) == 21
    assert List.last(given).id == pinned.id

    many = Learnings.retrieve_learnings(run, for(n <- 1..30, do: "<q#{n}>"))
    assert length(many) == 26
  end

  test "unembedded rules are left out, and when Vertex fails the run still gets its pinned rules", %{
    project: project,
    run: run
  } do
    learning(project, %{rule: "Embedded", kind: :convention}, embedding: [1.0])
    learning(project, %{rule: "Not yet embedded", kind: :convention})
    %{id: pinned_id} = learning(project, %{rule: "Pinned", kind: :convention, pinned: true})
    stub_vertex_down()

    assert [%Learning{id: ^pinned_id}] = Learnings.retrieve_learnings(run, ["the ticket", {"lib/a.ex", "+ x"}])
  end

  test "a run's retrievals are logged once per rule however often it starts", %{project: project, run: run} do
    %{id: pinned_id} = learning(project, %{rule: "Pinned", kind: :convention, pinned: true})

    Learnings.retrieve_learnings(run, [])
    Learnings.retrieve_learnings(run, [])

    assert [%LearningRetrieval{learning_id: ^pinned_id}] =
             Repo.all(from r in LearningRetrieval, where: r.run_id == ^run.id)
  end

  test "a role logs nothing, and no request is made when the project has no embedded rule", %{
    project: project,
    engineer: engineer
  } do
    stub_vertex()
    learning(project, %{rule: "Pinned", kind: :convention, pinned: true})

    assert [%Learning{rule: "Pinned"}] = Learnings.retrieve_learnings(engineer, ["the ticket"])
    refute_received {:embedded, _text, _task_type}
    assert [] = Repo.all(from r in LearningRetrieval, join: l in assoc(r, :learning), where: l.project_id == ^project.id)
  end

  test "Goth exiting at run start leaves the run with its pinned rules", %{project: project, run: run} do
    learning(project, %{rule: "Embedded", kind: :convention}, embedding: [1.0])
    %{id: pinned_id} = learning(project, %{rule: "Pinned", kind: :convention, pinned: true})
    stub(Rail, :goth_enabled?, fn -> true end)
    stub(Goth, :fetch, fn Rail.Goth -> exit(:noproc) end)

    assert [%Learning{id: ^pinned_id}] = Learnings.retrieve_learnings(run, ["the ticket"])
  end
end
