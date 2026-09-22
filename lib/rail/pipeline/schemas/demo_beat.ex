defmodule Rail.Pipeline.Schemas.DemoBeat do
  @moduledoc """
  One caption in a demo, and the moment it belongs to.

  The agent wrote the words and Rail wrote the time. That split is the whole
  design: an agent cannot know how long the browser took to paint, and a
  recording cannot know what is about to be shown.

  A beat has two clocks. `recorded_ms` is where it was said, on the recording's
  own clock. `at_ms` is where it plays in the video, which is the same thing
  until the video is encoded and then is not, because the encode squeezes out
  the time nothing happened. The panel only ever wants `at_ms`; the encode only
  ever wants `recorded_ms`.

  `criterion` is the acceptance criterion this beat proves, where it proves one.
  It is what lets a reader ask whether the walkthrough covered the ticket rather
  than wandered around the application, and it is empty for the beats that are
  getting from one place to another.
  """

  defstruct [:at_ms, :recorded_ms, :text, :criterion]

  # A caption is read at a few words a second. Short ones still need long enough
  # to register, and long ones are read by skimming rather than word by word.
  @ms_per_word 300
  @min_reading_ms 2_000
  @max_reading_ms 7_000

  @doc """
  How long `beat` has to stay up to be read.
  """
  def reading_ms(%__MODULE__{text: text}) do
    text |> String.split() |> length() |> Kernel.*(@ms_per_word) |> max(@min_reading_ms) |> min(@max_reading_ms)
  end

  @doc """
  Where in the video a beat falls, as a person reads a clock.
  """
  def stamp(%__MODULE__{at_ms: at_ms}), do: stamp(at_ms)

  def stamp(at_ms) when is_integer(at_ms) do
    seconds = div(at_ms, 1000)

    "#{div(seconds, 60)}:#{seconds |> rem(60) |> to_string() |> String.pad_leading(2, "0")}"
  end
end
