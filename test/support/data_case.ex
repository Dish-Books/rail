defmodule Rail.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Mimic
      import Rail.DataCase
      import Rail.Scope, only: [user_scope: 0, user_scope: 1, temp_user_scope: 0, temp_user_scope: 1, system_scope: 0]
      import RailTest.Helpers

      alias Rail.Repo

      setup :verify_on_exit!
      setup :stub_agent_spawn
      setup :stub_git_repo_check
    end
  end

  setup_all tags do
    if tags[:shared_sandbox] do
      pid = Sandbox.start_owner!(Rail.Repo, shared: false)
      Sandbox.allow(Rail.Repo, pid, self())
      ExUnit.Callbacks.on_exit(fn -> Sandbox.stop_owner(pid) end)
      %{sandbox_owner: pid}
    else
      :ok
    end
  end

  setup tags do
    Rail.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Keeps every test off the real agent CLIs.

  Dispatch is on in test, the same as anywhere else, so what stops a test
  spawning `claude` is this: the spawn boundary answers with a pretend pid. A
  test that is about spawning overrides it with its own `expect/3`, or tags
  itself `@moduletag :real_spawn` to run a real child.
  """
  def stub_agent_spawn(%{real_spawn: true}), do: :ok

  def stub_agent_spawn(_context) do
    Mimic.stub(Rail.Tools, :spawn_os_process, fn _executable, _args, _opts ->
      {:ok, nil, System.unique_integer([:positive])}
    end)

    Mimic.stub(Rail.Tools, :os_process_alive?, fn _os_pid -> false end)
    Mimic.stub(Rail.Tools, :terminate_os_process, fn _os_pid, _opts -> :ok end)

    :ok
  end

  @doc """
  Lets a project be saved with any `clone_path`.

  A project's checkout is only read when a worktree is made from it, so a test
  that never makes one has no reason to put a repository on disk. A test about
  the check overrides it with its own `expect/3`.
  """
  def stub_git_repo_check(_context) do
    Mimic.stub(Rail.Git, :git_repo?, fn _path -> true end)

    :ok
  end

  def setup_sandbox(tags) do
    if is_pid(tags[:sandbox_owner]) do
      Sandbox.allow(Rail.Repo, tags[:sandbox_owner], self())
    else
      shared? = not Map.get(tags, :async, false)
      pid = Sandbox.start_owner!(Rail.Repo, shared: shared?)
      ExUnit.Callbacks.on_exit(fn -> Sandbox.stop_owner(pid) end)
    end

    :ok
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _match, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
