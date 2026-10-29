defmodule Rail.Git.Actions.DeleteViewedFilesTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Users

  setup %{project: project} do
    [task, other] =
      for external_id <- ["lin_dvf_1", "lin_dvf_2"] do
        {:ok, task} =
          %Issue{}
          |> Issue.tracker_changeset(%{
            project_id: project.id,
            external_id: external_id,
            identifier: external_id,
            title: external_id,
            state: :in_progress
          })
          |> Repo.insert!()
          |> Repo.preload(:project)
          |> Pipeline.create_task(:review)

        task
      end

    {:ok, reader} =
      Users.register_oauth_user(%{github_id: "gh_dvf", login: "dvf-reader", email: "dvf-reader@example.com"})

    %{task: task, other: other, scope: user_scope(user: reader)}
  end

  test "deletes the task's marks and leaves another task's", %{task: task, other: other, scope: scope} do
    {:ok, _diff} = Git.set_file_viewed(scope, task, :diff, "lib/a.ex", "digest_a", true)
    {:ok, _plan} = Git.set_file_viewed(scope, task, :plan, "lib/b.ex", "digest_b", true)
    {:ok, _kept} = Git.set_file_viewed(scope, other, :diff, "lib/a.ex", "digest_c", true)

    assert :ok = Git.delete_viewed_files(task)

    assert Git.list_viewed_files(scope, task, :diff) == %{}
    assert Git.list_viewed_files(scope, task, :plan) == %{}
    assert Git.list_viewed_files(scope, other, :diff) == %{"lib/a.ex" => "digest_c"}
  end
end
