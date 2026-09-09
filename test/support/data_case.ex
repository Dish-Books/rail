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
