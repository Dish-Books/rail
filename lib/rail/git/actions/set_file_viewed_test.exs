defmodule Rail.Git.Actions.SetFileViewedTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Git.Schemas.ViewedFile
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Users

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_vwf_1", "identifier" => "VWF-1", "title" => "Viewed Files"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Viewed Files"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, ada} =
      Users.register_oauth_user(%{github_id: "gh_vwf_ada", login: "ada", email: "ada@example.com"})

    {:ok, grace} =
      Users.register_oauth_user(%{github_id: "gh_vwf_grace", login: "grace", email: "grace@example.com"})

    %{task: task, ada: user_scope(user: ada), grace: user_scope(user: grace)}
  end

  test "marks a file read for the person who read it", %{task: task, ada: ada} do
    {:ok, %ViewedFile{}} = Git.set_file_viewed(ada, task, "lib/rail/feature.ex", "digest_1", true)

    assert Git.list_viewed_files(ada, task) == %{"lib/rail/feature.ex" => "digest_1"}
  end

  test "one person's marks are not another's", %{task: task, ada: ada, grace: grace} do
    {:ok, %ViewedFile{}} = Git.set_file_viewed(ada, task, "lib/rail/feature.ex", "digest_1", true)

    assert Git.list_viewed_files(grace, task) == %{}
  end

  test "re-reading a file that moved records the digest it has now", %{task: task, ada: ada} do
    {:ok, %ViewedFile{}} = Git.set_file_viewed(ada, task, "lib/rail/feature.ex", "digest_1", true)
    {:ok, %ViewedFile{}} = Git.set_file_viewed(ada, task, "lib/rail/feature.ex", "digest_2", true)

    assert Git.list_viewed_files(ada, task) == %{"lib/rail/feature.ex" => "digest_2"}
  end

  test "unmarking forgets the file", %{task: task, ada: ada} do
    {:ok, %ViewedFile{}} = Git.set_file_viewed(ada, task, "lib/rail/feature.ex", "digest_1", true)
    {:ok, %ViewedFile{}} = Git.set_file_viewed(ada, task, "lib/rail/feature.ex", "digest_1", false)

    assert Git.list_viewed_files(ada, task) == %{}
  end

  test "unmarking a file nobody marked changes nothing", %{task: task, ada: ada} do
    assert {:ok, nil} = Git.set_file_viewed(ada, task, "lib/rail/feature.ex", "digest_1", false)
  end

  test "a scope with no user has read nothing", %{task: task} do
    assert Git.list_viewed_files(system_scope(), task) == %{}
  end
end
