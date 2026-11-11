defmodule Rail.Issues.Workers.EmbedIssuesTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.EmbedIssues
  alias Rail.Learnings
  alias Rail.Projects

  setup do
    key = "EMB#{System.unique_integer([:positive])}"

    {:ok, local} =
      Projects.create_project(system_scope(), %{
        name: "Embedded",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} =
      Issues.create_issue(system_scope(), local, %{title: "Rows show no wait time", description: "Up next lists none."})

    %{local: local, issue: issue}
  end

  test "embeds a ticket with none from its title and description, and leaves it alone while they stay the same", %{
    issue: %Issue{id: issue_id}
  } do
    stub_vertex()

    assert :ok = perform_job(EmbedIssues, %{})
    assert_received {:embedded, "Rows show no wait time\n\nUp next lists none.", "RETRIEVAL_DOCUMENT"}

    digest = Base.encode16(:crypto.hash(:md5, "Rows show no wait time\n\nUp next lists none."), case: :lower)

    assert {%Pgvector{}, ^digest} =
             Repo.one(from i in Issue, where: i.id == ^issue_id, select: {i.embedding, i.embedding_digest})

    assert :ok = perform_job(EmbedIssues, %{})
    refute_received {:embedded, "Rows show no wait time" <> _description, _task_type}
  end

  test "a ticket retitled after it was embedded is embedded again on the next run", %{
    local: local,
    issue: %Issue{id: issue_id} = issue
  } do
    stub_vertex()
    assert :ok = perform_job(EmbedIssues, %{})

    {:ok, _edited} = Issues.edit_issue(user_scope(project_ids: [local.id]), issue, %{"title" => "Wait times on Up next"})

    assert :ok = perform_job(EmbedIssues, %{})
    assert_received {:embedded, "Wait times on Up next\n\nUp next lists none.", "RETRIEVAL_DOCUMENT"}

    digest = Base.encode16(:crypto.hash(:md5, "Wait times on Up next\n\nUp next lists none."), case: :lower)
    assert %Issue{embedding_digest: ^digest} = Repo.get!(Issue, issue_id)
  end

  test "an edit that lands while its embedding is made leaves the ticket for the next run", %{
    issue: %Issue{id: issue_id}
  } do
    stub_vertex()

    Req.Test.stub(Rail.Learnings.Clients.Vertex, fn conn ->
      Repo.update_all(from(i in Issue, where: i.id == ^issue_id), set: [title: "Edited mid-call"])
      Req.Test.json(conn, %{"predictions" => [%{"embeddings" => %{"values" => far()}}]})
    end)

    assert :ok = perform_job(EmbedIssues, %{})
    assert %Issue{title: "Edited mid-call", embedding_digest: nil} = Repo.get!(Issue, issue_id)
  end

  test "a ticket whose embedding fails stays unembedded for the next run", %{issue: %Issue{id: issue_id}} do
    stub_vertex_down()

    assert :ok = perform_job(EmbedIssues, %{})
    assert %Issue{embedding_digest: nil} = Repo.get!(Issue, issue_id)
  end

  test "with Goth off a run embeds nothing and calls nothing", %{issue: %Issue{id: issue_id}} do
    reject(Learnings, :embed_document, 1)

    assert :ok = perform_job(EmbedIssues, %{})
    assert %Issue{embedding_digest: nil} = Repo.get!(Issue, issue_id)
  end
end
