defmodule Rail.Issues.Actions.LinkUrlTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueLink
  alias Rail.Issues.Workers.LinkTrackerUrl
  alias Rail.Projects

  setup do
    key = "Lnk#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Linked",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Reported in Slack"})

    %{issue: issue}
  end

  test "queues the link rather than making it", %{issue: issue} do
    assert {:ok, %Oban.Job{}} = Issues.link_url(issue, "https://slack.example/archives/C1/p1", "Slack thread")

    assert_enqueued(
      worker: LinkTrackerUrl,
      args: %{issue_id: issue.id, url: "https://slack.example/archives/C1/p1", title: "Slack thread"}
    )
  end

  test "the job lists the link on the issue once, however often it runs, and tells open pages", %{
    issue: %Issue{id: issue_id} = issue
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    {:ok, job} = Issues.link_url(issue, "https://slack.example/archives/C1/p1", "Slack thread")

    assert :ok = perform_job(LinkTrackerUrl, job.args)
    assert_receive {:issue_changed, ^issue_id}
    assert :ok = perform_job(LinkTrackerUrl, job.args)

    assert {:ok, %Issue{links: [%IssueLink{url: "https://slack.example/archives/C1/p1", title: "Slack thread"}]}} =
             Issues.get_issue(issue_id, preload: [:links])
  end

  test "an issue gone before the job runs has nothing to link", %{issue: issue} do
    {:ok, job} = Issues.link_url(issue, "https://slack.example/archives/C1/p1", "Slack thread")
    Repo.delete!(issue)

    assert :ok = perform_job(LinkTrackerUrl, job.args)
  end

  test "the same URL queued twice for an issue is one job", %{issue: issue} do
    {:ok, %Oban.Job{id: job_id}} = Issues.link_url(issue, "https://slack.example/archives/C1/p1", "Slack thread")

    assert {:ok, %Oban.Job{id: ^job_id, conflict?: true}} =
             Issues.link_url(issue, "https://slack.example/archives/C1/p1", "Slack thread")
  end
end
