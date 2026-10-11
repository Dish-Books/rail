defmodule Rail.Pipeline.Actions.CreateFindingCommentTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Users

  setup %{project: project} do
    task = learnings_task(project, "CFC-1", :review)
    other = learnings_task(project, "CFC-2", :review)
    on_exit(fn -> Enum.each([task, other], &File.rm_rf(&1.scratch_path)) end)

    attrs = %{
      kind: :code,
      raised_by: :code_reviewer,
      title: "Nil crashes the page",
      problem: "It crashes.",
      file: "lib/a.ex",
      line: 3,
      fix: "Guard it.",
      why: "It crashes.",
      rule: "Every caller handles nil.",
      severity: :major,
      recommendation: :fix,
      places: [%{file: "lib/a.ex", line: 3, label: "handle/1"}, %{file: "lib/b.ex", line: 9}],
      evidence: [%{name: "range", kind: :code, file: "lib/a.ex", line: 3}]
    }

    {:ok, finding} = Pipeline.save_finding(task, Map.put(attrs, :key, "nil-crash"))
    {:ok, elsewhere} = Pipeline.save_finding(other, Map.put(attrs, :key, "nil-crash"))
    {:ok, _pass} = Pipeline.save_review(task)

    {:ok, %{id: user_id} = ada} =
      Users.register_oauth_user(%{github_id: "gh_cfc_ada", login: "ada", email: "ada@example.com"})

    %{task: task, finding: finding, elsewhere: elsewhere, ada: user_scope(user: ada), user_id: user_id}
  end

  # The label and the quote are the finding's, never the client's.
  test "saves the comment on a piece, quoting it as the finding reads, for its author", %{
    task: %{id: task_id} = task,
    finding: %{id: finding_id} = finding,
    ada: ada,
    user_id: user_id
  } do
    assert {:ok,
            %FindingComment{
              task_id: ^task_id,
              user_id: ^user_id,
              finding_id: ^finding_id,
              finding: %{key: "nil-crash"},
              piece: :place,
              index: 0,
              label: "Place 1, handle/1",
              quote: "lib/a.ex:3",
              body: "Name the guard.",
              status: :unsent
            }} =
             Pipeline.create_finding_comment(ada, task, %{
               "finding_id" => finding.id,
               "piece" => "place",
               "index" => 0,
               "body" => " Name the guard. ",
               "label" => "Forged",
               "quote" => "Forged",
               "status" => "sent"
             })
  end

  test "takes a comment on a finding however it is ruled, and after the review is finished, merged too", %{
    project: project,
    task: task,
    finding: finding,
    ada: ada
  } do
    attrs = %{"finding_id" => finding.id, "piece" => "fix", "body" => "Guard it higher up."}
    assert {:ok, %FindingComment{label: "Fix", quote: "Guard it."}} = Pipeline.create_finding_comment(ada, task, attrs)

    {:ok, skipped} = Pipeline.decide_finding(system_scope(), finding, :skip)
    assert {:ok, %FindingComment{}} = Pipeline.create_finding_comment(ada, task, attrs)

    {:ok, _fixed} = Pipeline.decide_finding(system_scope(), skipped, :fix)
    assert {:ok, %FindingComment{}} = Pipeline.create_finding_comment(ada, task, attrs)

    {:ok, _skipped} = Pipeline.decide_finding(system_scope(), finding, :skip)
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

    {:ok, task} = Pipeline.update_task(task, %{pr_number: nil})
    {:ok, _finished} = Pipeline.start_fix_round(system_scope(), run)

    assert [%{finished_at: %DateTime{}}] = Pipeline.read_review(task)
    assert %Task{stage: :finalize} = finalizing = Repo.reload!(task)
    assert {:ok, %FindingComment{}} = Pipeline.create_finding_comment(ada, task, attrs)

    {:ok, _merged} = Pipeline.update_task(finalizing, %{stage: :merged})
    assert {:ok, %FindingComment{}} = Pipeline.create_finding_comment(ada, task, attrs)
  end

  test "refuses a piece the finding lacks, another task's finding, a task back before Review, and a cleaned-up task", %{
    task: task,
    finding: finding,
    elsewhere: elsewhere,
    ada: ada
  } do
    attrs = %{"finding_id" => finding.id, "piece" => "rule", "body" => "Say which callers."}

    assert {:error, :not_found} = Pipeline.create_finding_comment(ada, task, %{attrs | "finding_id" => elsewhere.id})
    assert {:error, :not_found} = Pipeline.create_finding_comment(ada, task, %{attrs | "finding_id" => "fnd_nope"})
    assert {:error, :not_found} = Pipeline.create_finding_comment(ada, task, Map.delete(attrs, "finding_id"))
    assert {:error, :not_found} = Pipeline.create_finding_comment(ada, task, %{attrs | "piece" => "verdict"})

    assert {:error, :not_found} =
             Pipeline.create_finding_comment(ada, task, Map.merge(attrs, %{"piece" => "place", "index" => 2}))

    assert {:error, %Ecto.Changeset{}} = Pipeline.create_finding_comment(ada, task, %{attrs | "body" => " "})

    {:ok, engineering} = Pipeline.update_task(task, %{stage: :engineer})
    assert {:error, {:invalid_stage, :engineer}} = Pipeline.create_finding_comment(ada, task, attrs)

    {:ok, _cleaned} = Pipeline.update_task(engineering, %{stage: :finalize, cleaned_up_at: DateTime.utc_now()})
    assert {:error, :cleaned_up} = Pipeline.create_finding_comment(ada, task, attrs)
    assert Repo.all(FindingComment) == []
  end

  test "tells the author's pages on the task, and nobody else's", %{
    task: %{id: task_id} = task,
    finding: finding,
    ada: ada
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "finding_comments:#{task_id}:#{ada.user.id}")
    Phoenix.PubSub.subscribe(Rail.PubSub, "finding_comments:#{task_id}:usr_someone_else")

    {:ok, _saved} =
      Pipeline.create_finding_comment(ada, task, %{"finding_id" => finding.id, "piece" => "title", "body" => "Hi."})

    assert_received {:finding_comments_changed, ^task_id}
    refute_received {:finding_comments_changed, _task_id}
  end
end
