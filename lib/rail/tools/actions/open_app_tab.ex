defmodule Rail.Tools.Actions.OpenAppTab do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  @doc """
  Opens `url` in the browser `name` on `task`, starting it if it is not open, with `cookies` set first in its own
  context, as `Network.setCookie` takes each. Returns `:ok` or why the browser could not open.
  """
  def open_app_tab(%Task{} = task, name, url, cookies) when is_binary(name) and is_binary(url) and is_list(cookies) do
    with {:ok, pid} <- Tools.start_browser_session(task, name),
         :ok <- set_cookies(pid, cookies) do
      BrowserSession.sign_in(pid, url, nil)
    end
  end

  defp set_cookies(pid, cookies) do
    Enum.reduce_while(cookies, :ok, fn cookie, :ok ->
      case BrowserSession.call(pid, "Network.setCookie", cookie) do
        {:ok, %{"success" => true}} -> {:cont, :ok}
        {:ok, _refused} -> {:halt, {:error, {:cookie_refused, cookie.name}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
