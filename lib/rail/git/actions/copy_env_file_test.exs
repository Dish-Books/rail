defmodule Rail.Git.Actions.CopyEnvFileTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Tools

  setup do
    create_task_checkout(project: [worktree_setup_script: "bin/setup"])
  end

  test "a checkout with no .env of its own gets the clone's lines between Rail's markers, ignored by git", %{
    project: project,
    task: task,
    checkout: checkout
  } do
    File.write!(Path.join(project.clone_path, ".env"), "# A comment\n\nFOO=bar\n")

    assert :ok = Git.copy_env_file(project, task)

    assert File.read!(Path.join(checkout, ".env")) == """
           # >>> Rail: the project's .env, rewritten on every save >>>
           # A comment
           FOO=bar
           # <<< Rail: the project's .env <<<
           """

    assert git!(checkout, ["status", "--porcelain"]) == ""
    refute File.read!(Path.join(project.clone_path, ".git/info/exclude")) =~ "/.env"
  end

  test "a checkout's own lines are kept below the block, unless they set what the project's do", %{
    project: project,
    task: task,
    checkout: checkout
  } do
    File.write!(Path.join(project.clone_path, ".env"), "FOO=bar\n")
    File.write!(Path.join(checkout, ".env"), "PORT=4100\nexport FOO=mine\n")

    assert :ok = Git.copy_env_file(project, task)
    assert :ok = Git.copy_env_file(project, task)

    assert File.read!(Path.join(checkout, ".env")) == """
           # >>> Rail: the project's .env, rewritten on every save >>>
           FOO=bar
           # <<< Rail: the project's .env <<<
           PORT=4100
           """
  end

  test "a task still on a worktree of its project's clone has the clone's exclude file ignore it", %{
    project: project,
    task: task,
    clone: clone
  } do
    File.write!(Path.join(clone, ".env"), "FOO=bar\n")
    worktree = Path.join(clone, ".worktrees/copy-env")
    git!(clone, ["worktree", "add", "--quiet", "-b", "copy-env", worktree])

    assert :ok = Git.copy_env_file(project, %{task | worktree_path: worktree})
    assert git!(worktree, ["status", "--porcelain"]) == ""
  end

  test "a clone with no .env gives the checkout none", %{project: project, task: task, checkout: checkout} do
    assert :ok = Git.copy_env_file(project, task)
    refute File.exists?(Path.join(checkout, ".env"))
  end

  test "a checkout whose .env or exclude file cannot be read says which file", %{
    project: project,
    task: task,
    checkout: checkout
  } do
    File.write!(Path.join(project.clone_path, ".env"), "FOO=bar\n")
    File.mkdir_p!(Path.join(checkout, ".env"))
    message = "#{checkout}/.env: illegal operation on a directory"
    assert {:error, ^message} = Git.copy_env_file(project, task)

    File.rm_rf!(Path.join(checkout, ".env"))
    File.rm!(Path.join(checkout, ".git/info/exclude"))
    File.mkdir_p!(Path.join(checkout, ".git/info/exclude"))
    assert {:error, "#{checkout}/.git/info/exclude: illegal operation on a directory"} == Git.copy_env_file(project, task)

    File.rm_rf!(Path.join(checkout, ".git/info"))
    File.write!(Path.join(checkout, ".git/info"), "")
    assert {:error, "#{checkout}/.git/info: not a directory"} == Git.copy_env_file(project, task)
  end

  test "a clone whose .env cannot be read says which file", %{project: project, task: task} do
    File.mkdir_p!(Path.join(project.clone_path, ".env"))
    source = Path.join(project.clone_path, ".env")

    assert {:error, ^source <> ": " <> _reason} = Git.copy_env_file(project, task)
  end

  describe "in a sandbox" do
    setup %{project: project} do
      stub(Rail, :sandbox_runtime, fn -> :docker end)
      File.write!(Path.join(project.clone_path, ".env"), "FOO=bar\n")
      :ok
    end

    test "reads the sandbox's .env and exclude file and writes both back, merged", %{
      project: project,
      task: %{worktree_path: path} = task
    } do
      env = Path.join(path, ".env")
      exclude = Path.join(path, ".git/info/exclude")
      test = self()

      stub(Tools, :call_sandbox, fn
        ^task, "read", %{"path" => ^env} ->
          {:ok, %{"data" => Base.encode64("PORT=4100\nFOO=mine\n")}}

        ^task, "read", %{"path" => ^exclude} ->
          {:ok, %{"data" => Base.encode64("# git ls-files\n")}}

        ^task, "write", %{"files" => files} ->
          send(test, {:wrote, files})
          {:ok, %{}}
      end)

      assert :ok = Git.copy_env_file(project, task)

      assert_received {:wrote,
                       [
                         %{"path" => ^env, "data" => written_env, "mode" => 0o644},
                         %{"path" => ^exclude, "data" => written_exclude, "mode" => 0o644}
                       ]}

      assert Base.decode64!(written_env) =~ "FOO=bar\n# <<< Rail: the project's .env <<<\nPORT=4100\n"
      assert Base.decode64!(written_exclude) == "# git ls-files\n/.env\n"
    end

    test "writes a sandbox with no .env one, and leaves an exclude file that already ignores it", %{
      project: project,
      task: task
    } do
      test = self()

      stub(Tools, :call_sandbox, fn
        ^task, "read", %{"path" => path} ->
          if String.ends_with?(path, "exclude"),
            do: {:ok, %{"data" => Base.encode64("/.env\n")}},
            else: {:ok, %{"missing" => true}}

        ^task, "write", %{"files" => files} ->
          send(test, {:wrote, files})
          {:ok, %{}}
      end)

      assert :ok = Git.copy_env_file(project, task)
      assert_received {:wrote, [%{"data" => written_env}]}
      assert Base.decode64!(written_env) =~ "\nFOO=bar\n"
    end

    test "says when the sandbox is not running, or could not be read", %{project: project, task: task} do
      path = Path.join(task.worktree_path, ".env")
      message = "#{path}: the task's sandbox is not running"
      assert {:error, ^message} = Git.copy_env_file(project, task)

      stub(Tools, :call_sandbox, fn _task, "read", _params -> {:error, :timeout} end)
      assert {:error, "#{path}: :timeout"} == Git.copy_env_file(project, task)
    end
  end
end
