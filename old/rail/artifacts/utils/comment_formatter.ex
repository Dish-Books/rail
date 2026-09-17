defmodule Rail.Artifacts.Utils.CommentFormatter do
  @moduledoc false

  alias Rail.Artifacts.Schemas.Demo

  @doc "Formats a Linear comment for a demo artifact."
  def format_demo_comment(%Demo{outcome: outcome} = demo) when outcome in ["declined", "failed"] do
    """
    ## Demo (v#{demo.version}): #{outcome}

    #{demo.note}
    """
  end

  def format_demo_comment(%Demo{} = demo) do
    segments = demo.segments || []
    total = length(segments)

    recorded =
      Enum.count(segments, fn seg ->
        outcome = get_val(seg, :outcome)
        outcome in [:recorded, "recorded"]
      end)

    header = "## Demo (v#{demo.version}): #{recorded}/#{total} criteria recorded\n\n"

    body = Enum.map_join(segments, "\n\n", &format_demo_segment/1)

    header <> body
  end

  defp format_demo_segment(seg) do
    idx = get_val(seg, :criterion_index)
    criterion = get_val(seg, :criterion)
    outcome = get_val(seg, :outcome)
    title = "### Criterion #{idx}: #{criterion}"
    outcome_str = to_string(outcome)

    case outcome_str do
      "recorded" ->
        frames = get_val(seg, :frames) || []

        frames_str =
          Enum.map_join(frames, "\n\n", fn frame ->
            caption = get_val(frame, :caption)
            caption = if caption && caption != "", do: caption, else: "Frame"
            url = get_val(frame, :url)
            "![#{caption}](#{url})\n*#{caption}*"
          end)

        "#{title}\n\n#{frames_str}"

      other ->
        note = get_val(seg, :note)
        "#{title}\n\n*Outcome: #{other}* - #{note}"
    end
  end

  defp get_val(item, key) when is_map(item) and is_atom(key) do
    Map.get(item, key) || Map.get(item, Atom.to_string(key))
  end
end
