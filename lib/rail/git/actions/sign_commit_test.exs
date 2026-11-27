defmodule Rail.Git.Actions.SignCommitTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Users.Schemas.User

  @email "ada-sign-commit@example.com"
  @empty_tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

  setup do
    %{issue: issue} = context = create_task_checkout()
    key = Path.join(System.tmp_dir!(), "rail_sign_commit_#{System.unique_integer([:positive])}")
    on_exit(fn -> Enum.each([key, key <> ".pub"], &File.rm/1) end)
    {_output, 0} = Tools.run("ssh-keygen", ["-t", "ed25519", "-N", "", "-C", @email, "-f", key], stderr_to_stdout: true)
    public = String.trim(File.read!(key <> ".pub"))

    {:ok, user} =
      %User{}
      |> User.changeset(%{
        github_id: "gh_sign_commit",
        login: "ada-sign-commit",
        name: "Ada Lovelace",
        email: @email,
        signing_key: File.read!(key),
        signing_public_key: public
      })
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: user.id})

    payload = """
    tree #{@empty_tree}
    author Ada Lovelace <#{@email}> 1700000000 +0000
    committer Ada Lovelace <#{@email}> 1700000000 +0000

    The work
    """

    Map.merge(context, %{public: public, payload: payload})
  end

  test "signs a commit the task's identity made with the owner's key, as git verify-commit accepts", %{
    task: task,
    checkout: checkout,
    public: public,
    payload: payload
  } do
    assert {:ok, "-----BEGIN SSH SIGNATURE-----\n" <> _rest = signature} = Git.sign_commit(task, payload)

    [headers, message] = String.split(payload, "\n\n", parts: 2)
    gpgsig = signature |> String.trim_trailing() |> String.split("\n") |> Enum.join("\n ")
    signed = Path.join(checkout, "signed")
    File.write!(signed, "#{headers}\ngpgsig #{gpgsig}\n\n#{message}")
    sha = String.trim(git!(checkout, ["hash-object", "-w", "-t", "commit", signed]))
    allowed = Path.join(checkout, "allowed_signers")
    File.write!(allowed, ~s(#{@email} namespaces="git" #{public}\n))

    assert git!(checkout, ["-c", "gpg.ssh.allowedSignersFile=#{allowed}", "verify-commit", sha]) =~
             ~s(Good "git" signature)

    # The key stays in the task's repository folder, where no sandbox reaches.
    assert File.regular?(Path.join([Task.repo_path(task), "rail", "signing", "key"]))
  end

  test "signs a tag the task's identity made", %{task: task} do
    tag = """
    object #{@empty_tree}
    type tree
    tag v1
    tagger Ada Lovelace <#{@email}> 1700000000 +0000

    v1
    """

    assert {:ok, "-----BEGIN SSH SIGNATURE-----\n" <> _rest} = Git.sign_commit(task, tag)
  end

  test "refuses a commit made as anyone else", %{task: task, payload: payload} do
    assert {:error, :not_the_task_identity} =
             Git.sign_commit(task, String.replace(payload, "committer Ada Lovelace <#{@email}>", "committer Eve <eve@x>"))
  end

  test "refuses anything but one well-formed commit or tag", %{task: task, payload: payload} do
    assert {:error, :not_a_commit} = Git.sign_commit(task, "anything at all")
    assert {:error, :not_a_commit} = Git.sign_commit(task, String.replace(payload, " 1700000000 +0000\n\n", "\n\n"))

    twice = String.replace(payload, "\n\n", "\ncommitter Ada Lovelace <#{@email}> 1700000000 +0000\n\n")
    assert {:error, :not_a_commit} = Git.sign_commit(task, twice)

    no_tree = String.replace(payload, "tree #{@empty_tree}", "tree nothing")
    assert {:error, :not_a_commit} = Git.sign_commit(task, no_tree)
  end

  test "says so when the owner has no key, or ssh-keygen will not sign with it", %{task: task, payload: payload} do
    user = Repo.get_by!(User, github_id: "gh_sign_commit")
    {:ok, user} = user |> User.changeset(%{signing_key: "not a key"}) |> Repo.update()
    assert {:error, output} = Git.sign_commit(task, payload)
    assert byte_size(output) > 0

    {:ok, _cleared} = user |> Ecto.Changeset.change(signing_key: nil, signing_public_key: nil) |> Repo.update()
    assert {:error, :no_signing_key} = Git.sign_commit(task, payload)
  end
end
