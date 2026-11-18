defmodule Rail.Pipeline.Actions.SplitMessageImages do
  @moduledoc false

  # The line `Rail.Pipeline.send_message/4` points the agent at each picture with.
  @attached_image ~r/^\[Attached image, open it with Read: ([^\]\n]+)\]$/m

  @doc """
  Splits a message as `Rail.Pipeline.send_message/4` queues it into `{words, files}`: what was typed, and the names of
  the pictures sent with it in the task's `attachments` folder, in order.
  """
  def split_message_images(text) when is_binary(text) do
    files = for [_line, path] <- Regex.scan(@attached_image, text), do: Path.basename(path)
    words = text |> String.replace(@attached_image, "") |> String.replace(~r/\n{3,}/, "\n\n") |> String.trim()
    {words, files}
  end
end
