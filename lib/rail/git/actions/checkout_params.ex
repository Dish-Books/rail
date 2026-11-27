defmodule Rail.Git.Actions.CheckoutParams do
  @moduledoc """
  What a sandbox's `checkout` call needs to make or refresh a task's checkout on its own disk: where, which branch,
  the git config Rail sets there, and the files it writes. The checkout commits as the ticket's owner and has
  `rail-sign` sign with their key, which stays with Rail, so the config names only its public half.
  """

  import Rail.Git.Utils.CommitAuthor
  import Rail.Git.Utils.MergeEnvBlock
  import Rail.Git.Utils.TaskBranch

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  @doc """
  Returns `{:ok, %{"path" => path, "branch" => branch, "config" => config, "files" => files}}`, each file a
  `%{"path" => relative path, "data" => base64, "mode" => mode}`, or `{:error, "<path>: <reason>"}` when the project's
  `.env` cannot be read. The `.env` goes only to a project with no setup script, which otherwise writes it itself.
  """
  def checkout_params(%Project{} = project, %Task{worktree_path: path} = task) when is_binary(path) do
    with {:ok, env} <- env_files(project) do
      {:ok,
       %{
         "path" => path,
         "branch" => task_branch(task),
         "config" => config(task),
         "files" => [file(".git/info/exclude", "/.env\n") | env]
       }}
    end
  end

  defp config(%Task{} = task) do
    author = commit_author(task)
    Map.merge(%{"user.name" => author.name, "user.email" => author.email}, signing(author))
  end

  defp signing(%{signing_key: key, signing_public_key: public}) when is_binary(key) and is_binary(public) do
    %{
      "gpg.format" => "ssh",
      "gpg.ssh.program" => "rail-sign",
      "user.signingkey" => "key::" <> public,
      "commit.gpgsign" => "true"
    }
  end

  defp signing(_unsigned), do: %{"commit.gpgsign" => "false"}

  defp env_files(%Project{clone_path: clone, worktree_setup_script: script}) when script in [nil, ""] do
    source = Path.join(clone, ".env")

    case File.read(source) do
      {:ok, project_env} -> {:ok, [file(".env", merge_env_block(project_env, nil))]}
      {:error, :enoent} -> {:ok, []}
      {:error, reason} -> {:error, "#{source}: #{:file.format_error(reason)}"}
    end
  end

  defp env_files(%Project{}), do: {:ok, []}

  defp file(path, text), do: %{"path" => path, "data" => Base.encode64(text), "mode" => 0o644}
end
