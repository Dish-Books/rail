defmodule Rail.Mcp.Utils.NamedBrowser do
  @moduledoc false

  import Rail.Mcp.Utils.BrowserName

  alias Rail.Tools

  @doc """
  The browser session a tool call acts on, as `{:ok, name, session}`. A name the
  call gives must be one browser_connect opened, so a slip is refused rather than
  answered from a new blank tab; with no name it is the stage's, opened if need be.
  """
  def named_browser(task, arguments, opts) do
    with {:ok, name} <- browser_name(arguments, opts) do
      case Tools.start_browser_session(task, name, [{:existing, Map.has_key?(arguments, "browser")} | opts]) do
        {:ok, session} ->
          {:ok, name, session}

        {:error, :no_browser} ->
          {:refused, "No browser named `#{name}` on this task. Call browser_connect with that name first."}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
