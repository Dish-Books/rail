defmodule Rail.Tools.Actions.AgentFailureReason do
  @moduledoc false

  @doc """
  Reads why an agent failed out of what it printed: the `result` text of the
  last stream-json line that carries one. An authentication failure also says
  where to sign the backend in again.

  Returns `nil` when the output gives no reason.
  """
  def agent_failure_reason(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(&reason/1)
  end

  defp reason(line) do
    with {:ok, %{"result" => text} = event} when is_binary(text) <- Jason.decode(line),
         text when text != "" <- String.trim(text) do
      if event["error"] == "authentication_failed" do
        "#{String.trim_trailing(text, ".")}. Sign the backend in again under Settings → Backends."
      else
        text
      end
    else
      _no_reason -> nil
    end
  end
end
