defmodule Rail.Issues.Actions.SearchIssuesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects

  setup do
    [local, other] =
      for name <- ["Searched", "Elsewhere"] do
        key = "SRC#{System.unique_integer([:positive])}"

        {:ok, project} =
          Projects.create_project(system_scope(), %{
            name: name,
            github_repo: "example/#{key}",
            github_installation_id: 1,
            tracker: :local,
            key: key,
            default_branch: "main",
            clone_path: "/tmp/#{key}"
          })

        project
      end

    %{local: local, other: other}
  end

  test "returns the project's embedded tickets nearest the search first, finished and archived ones included", %{
    local: %{id: local_id} = local,
    other: other
  } do
    {:ok, %Issue{id: near_id}} = Issues.create_issue(system_scope(), local, %{title: "Rows show no wait time"})
    {:ok, %Issue{id: done_id}} = Issues.create_issue(system_scope(), local, %{title: "Queue order by age"})
    {:ok, %Issue{id: archived_id}} = Issues.create_issue(system_scope(), local, %{title: "Slow Up next"})
    {:ok, _unembedded} = Issues.create_issue(system_scope(), local, %{title: "Never embedded"})
    {:ok, %Issue{id: elsewhere_id}} = Issues.create_issue(system_scope(), other, %{title: "Rows show no wait time"})

    for {id, components} <- [
          {near_id, [1.0]},
          {done_id, [1.0, 1.0]},
          {archived_id, [0.0, 1.0]},
          {elsewhere_id, [1.0]}
        ] do
      Repo.update_all(from(i in Issue, where: i.id == ^id), set: [embedding: Pgvector.new(vector(components))])
    end

    Repo.update_all(from(i in Issue, where: i.id == ^done_id), set: [state: :done])
    Repo.update_all(from(i in Issue, where: i.id == ^archived_id), set: [archived_at: DateTime.utc_now(:second)])
    stub_vertex(%{"how long" => vector([1.0])})

    assert {:ok,
            [
              %Issue{id: ^near_id, project_id: ^local_id, embedding: nil},
              %Issue{id: ^done_id, state: :done},
              %Issue{id: ^archived_id, archived_at: %DateTime{}}
            ]} = Issues.search_issues(local_id, "how long has each item been sitting there")

    assert_received {:embedded, "how long has each item been sitting there", "RETRIEVAL_QUERY"}
  end

  test "returns the embedding error when the search cannot be embedded", %{local: local} do
    stub_vertex_down()

    assert {:error, {:vertex_error, 503, _body}} = Issues.search_issues(local.id, "wait times")
  end
end
