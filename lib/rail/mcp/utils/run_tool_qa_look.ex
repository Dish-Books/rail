defmodule Rail.Mcp.Utils.RunToolQaLook do
  @moduledoc """
  Reads the current page as text: where it is, what it says, and what can be
  acted on.

  Cheaper and more exact than a picture, and it is what makes a following
  instruction answerable - an agent that can see the element list can name the
  thing it means. What a field is holding is part of it, because that is how a
  check asserts a value.
  """

  import Rail.Tools.Utils.ActionSpace

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  @doc """
  Returns what `task`'s browser is looking at, in the order a reader would want
  it.
  """
  def run_tool_qa_look(%Task{} = task, _arguments, opts) do
    with {:ok, session} <- Tools.start_browser_session(task, opts),
         {:ok, page} <- Tools.observe_browser(session) do
      {:ok, page_text(page)}
    end
  end

  defp page_text(page) do
    {elements, _targets, _controls} = action_space(Map.get(page, "actions", []))

    """
    #{page["url"]} - #{page["title"]}

    #{page["text"]}

    On this page:
    #{Enum.map_join(elements, "\n", &"  [#{&1["index"]}] #{&1["role"]} #{inspect(&1["label"])}#{holding(&1)}")}
    #{omitted(page)}
    """
  end

  # A page can offer more than a list can carry, and a dropdown with two thousand
  # entries is the usual reason. Saying so is the difference between a control
  # that is not there and one that was not listed: the second is reachable by
  # narrowing the page - scroll, filter, type into the dropdown - and a pass told
  # nothing would report it as missing.
  defp omitted(page) do
    [{page["omitted_actions"], "more controls"}, {page["omitted_options"], "more dropdown options"}]
    |> Enum.filter(fn {count, _what} -> is_integer(count) and count > 0 end)
    |> case do
      [] -> ""
      counted -> "\n" <> Enum.map_join(counted, "; ", fn {count, what} -> "#{count} #{what} not listed" end)
    end
  end

  defp holding(%{"value" => value}) when is_binary(value) and value != "", do: " holding #{inspect(value)}"
  defp holding(_element), do: ""
end
