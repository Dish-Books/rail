defmodule Rail.Learnings.Actions.BackfillLearningsTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Learnings.Schemas.ProcessedPullRequest
  alias Rail.Learnings.Workers.CollectPullRequest
  alias Rail.Learnings.Workers.IssueFinished
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  setup do
    unique = System.unique_integer([:positive])

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "teams" => %{
            "nodes" => [%{"id" => "lin_team_bfl", "states" => %{"nodes" => [%{"id" => "st_bfl", "type" => "triage"}]}}]
          }
        }
      })
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Backfill #{unique}",
        github_repo: "example/backfill",
        github_installation_id: 1,
        default_branch: "main",
        linear_team_key: "BFL",
        linear_workspace_id: "lw_test_seed",
        clone_path: "/tmp/repos/backfill.#{unique}"
      })

    {:ok, backend} = Tools.get_backend("bkd_test_seed")
    memory = Path.join([Backend.config_dir(backend), "projects", "-tmp-repos-backfill-#{unique}", "memory"])
    elsewhere = Path.join([Backend.config_dir(backend), "projects", "-tmp-repos-elsewhere-#{unique}", "memory"])
    File.mkdir_p!(memory)
    File.mkdir_p!(elsewhere)
    on_exit(fn -> File.rm_rf(Path.dirname(memory)) && File.rm_rf(Path.dirname(elsewhere)) end)

    File.write!(Path.join(memory, "MEMORY.md"), "- [Read git objects](read-git.md)\n")

    File.write!(Path.join(memory, "read-git.md"), """
    ---
    name: read-git-objects
    description: "Read git objects with :zlib when the sandbox has no git"
    metadata:
      node_type: memory
      type: reference
    ---

    The objects are loose under .git/objects.
    """)

    File.write!(Path.join(memory, "feedback.md"), "---\nname: factory\ntype: feedback\n---\n\nUse the factory.\n")
    File.write!(Path.join(elsewhere, "theirs.md"), "---\nname: theirs\n---\nNot this project's.\n")

    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _rest ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/example/backfill/pulls" ->
          Req.Test.json(conn, [
            %{"number" => 4, "merged_at" => "2026-01-01T00:00:00Z", "updated_at" => "2026-01-01T00:00:00Z"}
          ])
      end
    end)

    %{project: project, memory: memory, elsewhere: elsewhere}
  end

  test "queues every finished issue's task and every merged PR, and imports each memory file as a proposal", %{
    project: project,
    memory: memory,
    elsewhere: elsewhere
  } do
    done = learnings_task(project, "BFL-1")
    {:ok, _issue} = Issues.update_issue(done.issue, %{state: :done})
    extracted = learnings_task(project, "BFL-2")
    {:ok, _issue} = Issues.update_issue(extracted.issue, %{state: :canceled})
    {:ok, _task} = Pipeline.update_task(extracted, %{learnings_extracted_at: DateTime.utc_now()})
    learnings_task(project, "BFL-3")

    assert {:ok, %{issues: 1, pull_requests: 1, memories: 2}} = Learnings.backfill_learnings(project)

    assert [_one] = all_enqueued(worker: IssueFinished)
    assert_enqueued(worker: IssueFinished, args: %{issue_id: done.issue_id})
    assert_enqueued(worker: CollectPullRequest, args: %{project_id: project.id, number: 4})

    assert [
             %LearningProposal{
               action: :add,
               summary: "Claude memory import",
               title: "factory",
               learning: %Learning{status: :proposed, kind: :convention, rule: "factory", why: "Use the factory."}
             },
             %LearningProposal{
               title: "read-git-objects",
               learning: %Learning{
                 kind: :environment,
                 rule: "Read git objects with :zlib when the sandbox has no git",
                 roles: []
               }
             }
           ] =
             Repo.all(
               from p in LearningProposal, where: p.project_id == ^project.id, order_by: p.title, preload: :learning
             )

    assert [] = Path.wildcard(Path.join(memory, "*.md"))
    assert [_theirs] = Path.wildcard(Path.join(elsewhere, "*.md"))
  end

  test "running it again repeats no work", %{project: project} do
    done = learnings_task(project, "BFL-4")
    {:ok, _issue} = Issues.update_issue(done.issue, %{state: :done})
    {:ok, _first} = Learnings.backfill_learnings(project)
    {:ok, _task} = Pipeline.update_task(done, %{learnings_extracted_at: DateTime.utc_now()})
    Repo.insert!(%ProcessedPullRequest{project_id: project.id, number: 4})
    Repo.delete_all(Oban.Job)

    assert {:ok, %{issues: 0, pull_requests: 0, memories: 0}} = Learnings.backfill_learnings(project)
    refute_enqueued(worker: IssueFinished)
    refute_enqueued(worker: CollectPullRequest)
    assert 2 == Repo.aggregate(from(p in LearningProposal, where: p.project_id == ^project.id), :count)
  end

  test "a file whose delete failed is not proposed twice, and an unreadable one is left alone", %{
    project: project,
    memory: memory
  } do
    {:ok, _first} = Learnings.backfill_learnings(project)
    File.write!(Path.join(memory, "read-git.md"), "---\nname: again\n---\nSame path, written back.\n")
    File.write!(Path.join(memory, "empty.md"), "")
    File.write!(Path.join(memory, "binary.md"), <<0xFF, 0xFE, 0x00>>)
    File.write!(Path.join(memory, "unterminated.md"), "---\nname: never closed\n")
    File.write!(Path.join(memory, "plain.md"), "A memory with no front matter.\nAnd a body.")

    assert {:ok, %{memories: 1}} = Learnings.backfill_learnings(project)

    assert Enum.sort(Enum.map(Path.wildcard(Path.join(memory, "*.md")), &Path.basename/1)) ==
             ["binary.md", "empty.md", "unterminated.md"]

    assert %Learning{rule: "A memory with no front matter.", why: "A memory with no front matter.\nAnd a body."} =
             Repo.one!(
               from l in Learning, where: l.project_id == ^project.id and l.rule == "A memory with no front matter."
             )
  end

  test "a failed PR listing is reported", %{project: project} do
    Req.Test.stub(Client, &Req.Test.json(Plug.Conn.put_status(&1, 401), %{"message" => "Bad credentials"}))

    assert {:error, {:github_api_error, 401, _body}} = Learnings.backfill_learnings(project)
  end
end
