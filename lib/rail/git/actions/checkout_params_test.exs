defmodule Rail.Git.Actions.CheckoutParamsTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Users.Schemas.User

  setup %{project: project} do
    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "Checkout Params"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    clone = Path.join(System.tmp_dir!(), "rail_checkout_params_#{System.unique_integer([:positive])}")
    File.mkdir_p!(clone)
    on_exit(fn -> Enum.each([clone, task.scratch_path], &File.rm_rf/1) end)

    %{task: task, issue: issue, project: %{project | clone_path: clone, worktree_setup_script: nil}}
  end

  test "names the checkout's path and branch, and has it commit unsigned as the bot for a ticket with nobody on it", %{
    project: project,
    task: %{worktree_path: path, worktree_name: branch} = task
  } do
    assert {:ok,
            %{
              "path" => ^path,
              "branch" => ^branch,
              "config" => %{"user.name" => "Rail", "user.email" => "rail[bot]@railai.dev", "commit.gpgsign" => "false"},
              "files" => [%{"path" => ".git/info/exclude", "data" => exclude, "mode" => 0o644}]
            }} = Git.checkout_params(project, task)

    assert Base.decode64!(exclude) == "/.env\n"
  end

  test "has rail-sign sign with the owner's key, naming only its public half", %{
    project: project,
    task: task,
    issue: issue
  } do
    {:ok, user} =
      %User{}
      |> User.changeset(%{
        github_id: "gh_checkout_params",
        login: "ada-checkout-params",
        name: "Ada Lovelace",
        email: "ada-checkout-params@example.com",
        signing_key: "-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n-----END OPENSSH PRIVATE KEY-----\n",
        signing_public_key: "ssh-ed25519 AAAAC3Nza ada"
      })
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: user.id})

    expected = %{
      "user.name" => "Ada Lovelace",
      "user.email" => "ada-checkout-params@example.com",
      "gpg.format" => "ssh",
      "gpg.ssh.program" => "rail-sign",
      "user.signingkey" => "key::ssh-ed25519 AAAAC3Nza ada",
      "commit.gpgsign" => "true"
    }

    assert {:ok, %{"config" => ^expected = config}} = Git.checkout_params(project, task)

    refute inspect(config) =~ "secret"
  end

  test "gives a project with no setup script its .env, and one with a script none", %{project: project, task: task} do
    File.write!(Path.join(project.clone_path, ".env"), "FOO=bar\n")

    assert {:ok, %{"files" => [%{"path" => ".git/info/exclude"}, %{"path" => ".env", "data" => env, "mode" => 0o644}]}} =
             Git.checkout_params(project, task)

    assert Base.decode64!(env) =~ "\nFOO=bar\n# <<< Rail: the project's .env <<<\n"

    assert {:ok, %{"files" => [%{"path" => ".git/info/exclude"}]}} =
             Git.checkout_params(%{project | worktree_setup_script: "bin/setup"}, task)
  end

  test "says which file it could not read", %{project: project, task: task} do
    File.mkdir_p!(Path.join(project.clone_path, ".env"))
    source = Path.join(project.clone_path, ".env")

    assert {:error, ^source <> ": illegal operation on a directory"} = Git.checkout_params(project, task)
  end
end
