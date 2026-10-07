defmodule Rail.Issues.Utils.GithubIssueLabels do
  @moduledoc """
  The labels a GitHub issue's Rail state and priority live in. Each starts with `rail:`, so none
  clashes with a label the repository already uses for something else.
  """

  # Open states are listed in the order an issue moves through them, so a later one is further along.
  @labels [
    %{name: "rail: triage", state: :triage, priority: nil, color: "d4c5f9", description: "Rail: waiting to be sorted"},
    %{name: "rail: backlog", state: :backlog, priority: nil, color: "c5def5", description: "Rail: accepted, not started"},
    %{name: "rail: todo", state: :todo, priority: nil, color: "bfdadc", description: "Rail: up next"},
    %{
      name: "rail: in progress",
      state: :in_progress,
      priority: nil,
      color: "fbca04",
      description: "Rail: being worked on"
    },
    %{name: "rail: in review", state: :in_review, priority: nil, color: "0e8a16", description: "Rail: in review"},
    %{name: "rail: priority urgent", state: nil, priority: :urgent, color: "b60205", description: "Rail: urgent"},
    %{name: "rail: priority high", state: nil, priority: :high, color: "d93f0b", description: "Rail: high priority"},
    %{
      name: "rail: priority medium",
      state: nil,
      priority: :medium,
      color: "fef2c0",
      description: "Rail: medium priority"
    },
    %{name: "rail: priority low", state: nil, priority: :low, color: "ededed", description: "Rail: low priority"}
  ]

  @doc """
  Every label Rail uses, each with the `:state` or `:priority` it stands for, its `:color` and `:description`.
  """
  def github_issue_labels, do: @labels
end
