defmodule Rail.Artifacts.Actions.GetAsset do
  @moduledoc false

  import Ecto.Query
  import Rail.Artifacts.Utils.MimeType

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Repo

  def get_asset(_scope, kind, id) do
    do_get_asset(to_string(kind), to_string(id))
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

  defp do_get_asset(_kind, _id), do: {:error, :not_found}

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
end
