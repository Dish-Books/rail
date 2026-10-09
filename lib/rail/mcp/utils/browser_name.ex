defmodule Rail.Mcp.Utils.BrowserName do
  @moduledoc false

  @doc """
  The browser a tool call names in `"browser"`, or the one named for the run's
  stage when it names none. Returns `{:ok, name}`, or `{:refused, text}` for a
  name Rail will not key a browser by.
  """
  def browser_name(arguments, opts) do
    name = Map.get(arguments, "browser") || to_string(Keyword.fetch!(opts, :stage))

    if is_binary(name) and String.match?(String.trim(name), ~r/^[\w -]{1,40}$/u),
      do: {:ok, String.trim(name)},
      else: {:refused, "`browser` is a name of up to 40 letters, digits, spaces, dashes or underscores."}
  end
end
