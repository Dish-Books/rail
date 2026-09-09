defmodule Rail.Artifacts.Actions.GetAsset do
  @moduledoc false

  import Ecto.Query
  import Rail.Artifacts.Utils.MimeType

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Repo
  alias Rail.Scope

  def get_asset(scope, kind, id) do
    if authorized?(scope) do
      do_get_asset(to_string(kind), to_string(id))
    else
      {:error, :not_authorized}
    end
  end

  defp authorized?(%Scope{system: true}), do: true
  defp authorized?(%Scope{user: %{}}), do: true
  defp authorized?(_scope), do: false

  defp do_get_asset("design", id) do
    query =
      from d in Design,
        where: fragment("?::text LIKE ?", d.directions, ^("%" <> id <> "%")),
        order_by: [desc: d.inserted_at]

    matching_direction =
      query
      |> Repo.all()
      |> Enum.find_value(&find_direction_in_design(&1, id))

    case matching_direction do
      %{} = asset -> {:ok, asset}
      nil -> {:error, :not_found}
    end
  end

  defp do_get_asset("demo", id) do
    query =
      from d in Demo,
        where: fragment("?::text LIKE ?", d.segments, ^("%" <> id <> "%")),
        order_by: [desc: d.inserted_at]

    matching_frame =
      query
      |> Repo.all()
      |> Enum.find_value(&find_frame_in_demo(&1, id))

    case matching_frame do
      %{} = asset -> {:ok, asset}
      nil -> {:error, :not_found}
    end
  end

  defp do_get_asset(kind, id) when kind in ["qa", "qa_report"] do
    query =
      from q in QaReport,
        where: fragment("?::text LIKE ?", q.rows, ^("%" <> id <> "%")),
        order_by: [desc: q.inserted_at]

    matching_artifact =
      query
      |> Repo.all()
      |> Enum.find_value(&find_artifact_in_report(&1, id))

    case matching_artifact do
      %{} = asset -> {:ok, asset}
      nil -> {:error, :not_found}
    end
  end

  defp do_get_asset(_kind, _id), do: {:error, :not_found}

  defp find_direction_in_design(design, id) do
    Enum.find_value(design.directions || [], fn dir ->
      if dir.linear_asset_id == id or dir.key == id do
        %{url: dir.still_url, task_id: design.task_id, content_type: mime_type(dir.still_url)}
      end
    end)
  end

  defp find_frame_in_demo(demo, id) do
    Enum.find_value(demo.segments || [], fn seg ->
      find_frame_in_segment(seg, demo.task_id, id)
    end)
  end

  defp find_frame_in_segment(seg, task_id, id) do
    Enum.find_value(seg.frames || [], fn frame ->
      if frame.linear_asset_id == id do
        %{url: frame.url, task_id: task_id, content_type: mime_type(frame.url)}
      end
    end)
  end

  defp find_artifact_in_report(report, id) do
    Enum.find_value(report.rows || [], fn row ->
      find_artifact_in_row(row, report.task_id, id)
    end)
  end

  defp find_artifact_in_row(row, task_id, id) do
    Enum.find_value(row.artifacts || [], fn art ->
      if art.name == id or (art.url && String.contains?(art.url, id)) do
        %{url: art.url, task_id: task_id, content_type: mime_type(art.url || art.name)}
      end
    end)
  end
end
