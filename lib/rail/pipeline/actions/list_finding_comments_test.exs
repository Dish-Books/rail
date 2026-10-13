defmodule Rail.Pipeline.Actions.ListFindingCommentsTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Users

  setup %{project: project} do
    task = learnings_task(project, "LFC-1", :review)
    other = learnings_task(project, "LFC-2", :review)
    on_exit(fn -> Enum.each([task, other], &File.rm_rf(&1.scratch_path)) end)

    attrs = %{
      key: "nil-crash",
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
      places: [%{file: "lib/a.ex", line: 3}],
      evidence: [%{name: "range", kind: :code, file: "lib/a.ex", line: 3}]
    }

    {:ok, finding} = Pipeline.save_finding(task, attrs)
    {:ok, elsewhere} = Pipeline.save_finding(other, attrs)

    {:ok, ada} =
      Users.register_oauth_user(%{
        github_id: "gh_lfc_ada",
        login: "ada-list-finding-comments",
        email: "ada-list-finding-comments@example.com"
      })

    {:ok, grace} =
      Users.register_oauth_user(%{
        github_id: "gh_lfc_grace",
        login: "grace-list-finding-comments",
        email: "grace-list-finding-comments@example.com"
      })

    %{
      task: task,
      other: other,
      finding: finding,
      elsewhere: elsewhere,
      ada: user_scope(user: ada),
      grace: user_scope(user: grace)
    }
  end

  test "lists only the reader's unsent comments on the task, in the order written, with their findings", %{
    task: task,
    other: other,
    finding: finding,
    elsewhere: elsewhere,
    ada: ada,
    grace: grace
  } do
    on = %{"finding_id" => finding.id, "piece" => "fix"}
    {:ok, %{id: first_id}} = Pipeline.create_finding_comment(ada, task, Map.put(on, "body", "First."))
    {:ok, %{id: second_id}} = Pipeline.create_finding_comment(ada, task, Map.put(on, "body", "Second."))
    {:ok, _theirs} = Pipeline.create_finding_comment(grace, task, Map.put(on, "body", "Grace's."))

    {:ok, _elsewhere} =
      Pipeline.create_finding_comment(ada, other, %{"finding_id" => elsewhere.id, "piece" => "fix", "body" => "There."})

    {:ok, %{id: sent_id}} = Pipeline.create_finding_comment(ada, task, Map.put(on, "body", "Sent."))
    Repo.update_all(from(c in FindingComment, where: c.id == ^sent_id), set: [status: :sent])

    assert [
             %FindingComment{id: ^first_id, finding: %{key: "nil-crash"}},
             %FindingComment{id: ^second_id}
           ] = Pipeline.list_finding_comments(ada, task)

    assert [%FindingComment{body: "Grace's."}] = Pipeline.list_finding_comments(grace, task)
  end
end
