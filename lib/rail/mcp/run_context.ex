defmodule Rail.Mcp.RunContext do
  @moduledoc """
  Who is calling the proxy: the live OS process whose token authenticated the
  request, the role that decides which tools it may use, and the issue's
  assigned user whose connections those tools go out on. `user` is nil when the
  issue is unassigned, and then the run has no tools that need an account.
  """

  defstruct [:os_process, :role, :user]
end
