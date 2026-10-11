defmodule Rail.Tools.Actions.ListBrowserContexts do
  @moduledoc """
  The browser contexts the shared Chrome is holding right now.

  A Chrome that restarted has none of the contexts it had before, and a session's
  row goes on naming one until something asks. This is what is asked: a row whose
  context is not here stands for a tab that is gone.

  A Chrome that is down, or too busy to answer, is not started to be asked: not
  knowing is said as such, so nobody settles a row on a guess.
  """

  import Rail.Tools.Utils.EnsureBrowserHost

  alias Rail.Tools.Browser

  @doc """
  Returns `{:ok, contexts}`, a `MapSet` of every browser context id Chrome holds,
  or `:unknown` when Chrome did not answer.
  """
  def list_browser_contexts do
    with {:ok, %{url: url}} <- ensure_browser_host(start: false),
         {:ok, connection} <- Browser.start_link(url: url) do
      answer = Browser.call(connection, "Target.getBrowserContexts", %{})
      GenServer.stop(connection, :normal, 1_000)

      case answer do
        {:ok, %{"browserContextIds" => ids}} -> {:ok, MapSet.new(ids)}
        {:error, _refused} -> :unknown
      end
    else
      {:error, _down} -> :unknown
    end
  end
end
