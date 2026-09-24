defmodule Rail.Git.Actions.CiEnv do
  @moduledoc false

  import Rail.Git.Utils.CommitAuthor

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  @doc """
  Returns the environment `project`'s CI runs `task`'s worktree in: the push
  credential, plus a git identity for a CI that commits, as its receipt does.

  The identity is the ticket owner's GitHub name and email, as `git config` sets
  it, since the machine CI runs on has no gitconfig of its own.
  """
  def ci_env(%Project{} = project, %Task{} = task) do
    %{name: name, email: email} = commit_author(task)

    with {:ok, env} <- Git.credential_env(project) do
      count = env |> Map.get("GIT_CONFIG_COUNT", "0") |> String.to_integer()

      {:ok,
       Map.merge(env, %{
         "GIT_CONFIG_COUNT" => Integer.to_string(count + 2),
         "GIT_CONFIG_KEY_#{count}" => "user.name",
         "GIT_CONFIG_VALUE_#{count}" => name,
         "GIT_CONFIG_KEY_#{count + 1}" => "user.email",
         "GIT_CONFIG_VALUE_#{count + 1}" => email
       })}
    end
  end
end
