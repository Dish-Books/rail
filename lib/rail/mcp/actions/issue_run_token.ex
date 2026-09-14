defmodule Rail.Mcp.Actions.IssueRunToken do
  @moduledoc false

  @doc """
  Mints a token for one spawned turn. Returns `{token, hash}`: the token goes to
  the agent CLI in its environment and is never stored; the hash goes on the
  `os_processes` row, which is what makes it valid.
  """
  def issue_run_token do
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    {token, :crypto.hash(:sha256, token)}
  end
end
