defmodule Rail.Artifacts.Utils.CommentFormatter do
  @moduledoc false

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Artifacts.Schemas.QaReport

  @doc "Formats a Linear comment for a design artifact."
  def format_design_comment(%Design{} = design, direction \\ nil) do
    chosen =
      direction ||
        find_direction(design.directions, design.picked_key) ||
        List.first(design.directions || [])

    if chosen do
      title = get_val(chosen, :title)
      notes = get_val(chosen, :notes)
      still_url = get_val(chosen, :still_url)

      """
      ## Design: #{title}

      #{notes}

      ![#{title}](#{still_url})

      [View live canvas](#{design.canvas_url})
      """
    else
      """
      ## Design (v#{design.version})

      [View live canvas](#{design.canvas_url})
      """
    end
  end

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

  @doc "Formats a Linear comment for a QA report."
  def format_qa_comment(%QaReport{} = qa_report) do
    rows = qa_report.rows || []

    passed =
      Enum.count(rows, fn r ->
        result = get_val(r, :result)
        result in [:pass, "pass"]
      end)

    failed =
      Enum.count(rows, fn r ->
        result = get_val(r, :result)
        result in [:fail, "fail"]
      end)

    skipped =
      Enum.count(rows, fn r ->
        result = get_val(r, :result)
        result in [:skip, "skip"]
      end)

    header = """
    ## QA Report

    Commit: `#{qa_report.commit || "unknown"}`
    Summary: #{passed} passed, #{failed} failed, #{skipped} skipped

    | Check | Result | Severity | Caused by change |
    |---|---|---|---|
    """

    table_rows =
      Enum.map_join(rows, "\n", fn row ->
        check = get_val(row, :check)
        result = get_val(row, :result)
        severity = get_val(row, :severity)
        caused = get_val(row, :caused_by_change)
        "| #{check} | #{result} | #{severity} | #{caused} |"
      end)

    header <> table_rows
  end

  defp find_direction(directions, picked_key) when is_list(directions) and is_binary(picked_key) do
    Enum.find(directions, fn dir ->
      get_val(dir, :key) == picked_key
    end)
  end

  defp find_direction(_directions, _picked_key), do: nil

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
