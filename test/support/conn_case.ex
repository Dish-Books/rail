defmodule RailWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      use RailWeb, :verified_routes

      import Mimic
      import Phoenix.ConnTest
      import Plug.Conn
      import Rail.DataCase, only: [errors_on: 1]
      import Rail.Scope, only: [user_scope: 0, user_scope: 1, temp_user_scope: 0, temp_user_scope: 1, system_scope: 0]
      import RailTest.Helpers
      import RailWeb.ConnCase

      @endpoint RailWeb.Endpoint

      setup :verify_on_exit!
      setup {Rail.DataCase, :stub_git_repo_check}
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
    conn = Phoenix.ConnTest.init_test_session(Phoenix.ConnTest.build_conn(), %{})
    {:ok, conn: conn}
  end
end
