defmodule Rail.Issues.Actions.LinkUrlTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueLink
  alias Rail.Issues.Workers.LinkTrackerUrl
  alias Rail.Projects

  # DataCase verifies Mimic, not Req.Test: without this a link that never went out would pass.
  setup {Req.Test, :verify_on_exit!}

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_link_url_1", "identifier" => "LNK-1", "title" => "Link Url Issue"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "Link Url Issue"})

    %{issue: issue}
  end

  test "queues the link rather than making it", %{issue: issue} do
    assert {:ok, %Oban.Job{}} = Issues.link_url(issue, "https://slack.example/archives/C1/p1", "Slack thread")

    assert_enqueued(
      worker: LinkTrackerUrl,
      args: %{issue_id: issue.id, url: "https://slack.example/archives/C1/p1", title: "Slack thread"}
    )
  end

  test "the job links the URL to the Linear ticket under its title", %{issue: issue} do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert %{
               "query" => "mutation AttachmentLinkURL" <> _rest,
               "variables" => %{
                 "issueId" => "lin_link_url_1",
                 "url" => "https://slack.example/archives/C1/p1",
                 "title" => "Slack thread"
               }
             } = conn |> Req.Test.raw_body() |> Jason.decode!()

      Req.Test.json(conn, %{"data" => %{"attachmentLinkURL" => %{"success" => true}}})
    end)

    {:ok, job} = Issues.link_url(issue, "https://slack.example/archives/C1/p1", "Slack thread")

    assert :ok = perform_job(LinkTrackerUrl, job.args)
  end

  test "a link Linear refuses fails the job, so it retries", %{issue: issue} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"attachmentLinkURL" => %{"success" => false}}})
    end)

    {:ok, job} = Issues.link_url(issue, "https://slack.example/archives/C1/p1", "Slack thread")

    assert {:error, {:linear_mutation_failed, "attachmentLinkURL"}} = perform_job(LinkTrackerUrl, job.args)
  end

  test "a Linear error fails the job as Linear said it", %{issue: issue} do
    Req.Test.expect(Rail.Linear, &Req.Test.json(Plug.Conn.put_status(&1, 500), %{"error" => "down"}))

    {:ok, job} = Issues.link_url(issue, "https://slack.example/archives/C1/p1", "Slack thread")

    assert {:error, {:linear_api_error, 500, %{"error" => "down"}}} = perform_job(LinkTrackerUrl, job.args)
  end

  test "an issue gone before the job runs has nothing to link", %{issue: issue} do
    {:ok, job} = Issues.link_url(issue, "https://slack.example/archives/C1/p1", "Slack thread")
    Repo.delete!(issue)

    assert :ok = perform_job(LinkTrackerUrl, job.args)
  end

  test "a GitHub issue has no place for a link, so nothing is sent", %{github_project: project} do
    issue = github_issue(project)
    {:ok, job} = Issues.link_url(issue, "https://slack.example/archives/C1/p1", "Slack thread")

    assert :ok = perform_job(LinkTrackerUrl, job.args)
  end

  test "the same URL queued twice for an issue is one job", %{issue: issue} do
    {:ok, %Oban.Job{id: job_id}} = Issues.link_url(issue, "https://slack.example/archives/C1/p1", "Slack thread")

    assert {:ok, %Oban.Job{id: ^job_id, conflict?: true}} =
             Issues.link_url(issue, "https://slack.example/archives/C1/p1", "Slack thread")
  end

  test "the job lists the link on a Rail-tracked issue once, however often it runs, and tells open pages" do
    key = "Lnk#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Rail-tracked",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, %Issue{id: issue_id}} = Issues.create_issue(system_scope(), project, %{title: "Reported in Slack"})
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    args = %{issue_id: issue_id, url: "https://slack.example/archives/C1/p1", title: "Slack thread"}

    assert :ok = perform_job(LinkTrackerUrl, args)
    assert_receive {:issue_changed, ^issue_id}
    assert :ok = perform_job(LinkTrackerUrl, args)

    assert {:ok, %Issue{links: [%IssueLink{url: "https://slack.example/archives/C1/p1", title: "Slack thread"}]}} =
             Issues.get_issue(issue_id, preload: [:links])
  end
end
