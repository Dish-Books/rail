defmodule Rail.Git.Actions.CiEnv do
  @moduledoc false

  import Rail.Git.Utils.CommitAuthor

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  @doc """
  Returns the environment `project`'s CI runs `task`'s worktree in: a git
  identity for a CI that commits, as its receipt does, and no credential.

  CI runs the branch's own scripts, which an agent wrote, so it gets nothing to
  push with. Rail pushes what it left instead, the commit with its
  `refs/ci-receipts/<tree>`, and only once it has seen CI pass on that tree
  (`Rail.Git.push_branch/3`). `RAIL_PUSHES_RECEIPT` tells a CI that pushes its own
  receipt elsewhere to leave it in the checkout, and git asks nobody for a
  password it does not have.

  The identity is the ticket owner's GitHub name and email, as `git config` sets
  it, since the machine CI runs on has no gitconfig of its own.
  """
  def ci_env(%Project{}, %Task{} = task) do
    %{name: name, email: email} = commit_author(task)

    {:ok,
     %{
       "RAIL_PUSHES_RECEIPT" => "1",
       "GIT_TERMINAL_PROMPT" => "0",
       "GIT_CONFIG_COUNT" => "2",
       "GIT_CONFIG_KEY_0" => "user.name",
       "GIT_CONFIG_VALUE_0" => name,
       "GIT_CONFIG_KEY_1" => "user.email",
       "GIT_CONFIG_VALUE_1" => email
     }}
  end
end
