defmodule Rail.Pipeline.Actions.TimeOutCoderabbitReviewTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.CoderabbitReview
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Users

  setup %{project: project} do
    scratch = Path.join(System.tmp_dir!(), "coderabbit_timeout_#{System.unique_integer([:positive])}")
    worktree = Path.join(scratch, "worktree")
    File.mkdir_p!(worktree)
    on_exit(fn -> File.rm_rf(scratch) end)
    stub(Git, :branch_fingerprint, fn _path -> %{head_sha: String.duplicate("e", 40), dirty_digest: "clean"} end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "CodeRabbit timeout"})
    {:ok, task} = Pipeline.create_task(issue, :review)

    {:ok, task} =
      Pipeline.update_task(task, %{pr_number: 153, worktree_path: worktree, scratch_path: Path.join(scratch, "scratch")})

    {:ok, _round} = Pipeline.create_round(task)

    {:ok, dev} =
      Users.register_oauth_user(%{github_id: "gh_crt_dev", login: "dev-crt", email: "dev-crt@example.com"})

    {:ok, dev} =
      Users.update_user(system_scope(), dev, %{
        project_ids: [project.id],
        github_token: "gho_dev_crt",
        github_token_expires_at: ~U[2100-01-01 00:00:00.000000Z]
      })

    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})))
    {:ok, review} = Pipeline.request_coderabbit_review(Scope.for_user(dev), task)

    {:ok, lead_role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, lead} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead_role.id,
        status: :running,
        conversation_id: "sess_coderabbit_timeout",
        started_at: DateTime.utc_now()
      })

    %{review: review, lead: lead}
  end

  test "a review that never answered times out once, and tells the lead", %{review: review, lead: lead} do
    assert {:ok, %CoderabbitReview{status: :timed_out, finished_at: %DateTime{}}} =
             Pipeline.time_out_coderabbit_review(review.id)

    assert %Run{pending_chat: note} = Repo.reload!(lead)
    assert note =~ "ended with nothing to add (No answer)"

    assert {:ok, :already_finished} = Pipeline.time_out_coderabbit_review(review.id)
  end

  test "a review deleted with its task is not found" do
    assert {:error, :not_found} = Pipeline.time_out_coderabbit_review("crv_missing")
  end
end
