defmodule Rail.Artifacts.Actions.Materialize do
  @moduledoc false

  import Ecto.Query

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Domain.Embeds.DemoFrame
  alias Rail.Domain.Embeds.DemoSegment
  alias Rail.Domain.Embeds.DesignDirection
  alias Rail.Domain.Embeds.QaArtifact
  alias Rail.Domain.Embeds.QaRow
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  def materialize(scope, target, dest_scratch_dir, opts \\ []) do
    if authorized?(scope) do
      do_materialize(target, dest_scratch_dir, opts)
    else
      {:error, :not_authorized}
    end
  end

  defp authorized?(%Scope{system: true}), do: true
  defp authorized?(%Scope{user: %{}}), do: true
  defp authorized?(_scope), do: false

  defp do_materialize(%Demo{} = demo, dest_scratch_dir, opts) do
    materialize_demo(demo, dest_scratch_dir, opts)
  end

  defp do_materialize(%Design{} = design, dest_scratch_dir, opts) do
    materialize_design(design, dest_scratch_dir, opts)
  end

  defp do_materialize(%QaReport{} = report, dest_scratch_dir, opts) do
    materialize_qa_report(report, dest_scratch_dir, opts)
  end

  defp do_materialize(task_target, dest_scratch_dir, opts) do
    task_id = extract_task_id(task_target)
    kind = Keyword.get(opts, :kind, :all)

    case kind do
      :demo ->
        case get_latest_demo(task_id) do
          %Demo{} = demo -> materialize_demo(demo, dest_scratch_dir, opts)
          nil -> {:error, :demo_not_found}
        end

      :design ->
        case get_latest_design(task_id) do
          %Design{} = design -> materialize_design(design, dest_scratch_dir, opts)
          nil -> {:error, :design_not_found}
        end

      :qa ->
        case get_latest_qa_report(task_id) do
          %QaReport{} = report -> materialize_qa_report(report, dest_scratch_dir, opts)
          nil -> {:error, :qa_report_not_found}
        end

      :all ->
        materialize_all(task_id, dest_scratch_dir, opts)
    end
  end

  defp extract_task_id(%{id: task_id}), do: to_string(task_id)
  defp extract_task_id(task_id) when is_binary(task_id), do: task_id
  defp extract_task_id(other), do: to_string(other)

  defp get_latest_demo(task_id) do
    Repo.one(from(d in Demo, where: d.task_id == ^task_id, order_by: [desc: d.version], limit: 1))
  end

  defp get_latest_design(task_id) do
    Repo.one(from(d in Design, where: d.task_id == ^task_id, order_by: [desc: d.version], limit: 1))
  end

  defp get_latest_qa_report(task_id) do
    Repo.one(from(q in QaReport, where: q.task_id == ^task_id, order_by: [desc: q.inserted_at], limit: 1))
  end

  defp materialize_all(task_id, dest_scratch_dir, opts) do
    results = %{}

    results =
      case get_latest_design(task_id) do
        %Design{} = design ->
          {:ok, path} = materialize_design(design, dest_scratch_dir, opts)
          Map.put(results, :design, path)

        nil ->
          results
      end

    results =
      case get_latest_demo(task_id) do
        %Demo{} = demo ->
          {:ok, path} = materialize_demo(demo, dest_scratch_dir, opts)
          Map.put(results, :demo, path)

        nil ->
          results
      end

    results =
      case get_latest_qa_report(task_id) do
        %QaReport{} = report ->
          {:ok, path} = materialize_qa_report(report, dest_scratch_dir, opts)
          Map.put(results, :qa, path)

        nil ->
          results
      end

    {:ok, results}
  end

  defp materialize_design(%Design{} = design, dest_scratch_dir, opts) do
    design_dir =
      if String.ends_with?(dest_scratch_dir, "design") do
        dest_scratch_dir
      else
        Path.join(dest_scratch_dir, "design")
      end

    File.mkdir_p!(design_dir)

    with {:ok, token} <- resolve_token(opts),
         {:ok, directions_data} <- download_design_directions(design.directions || [], design_dir, token, opts) do
      manifest = %{
        "version" => design.version,
        "canvasUrl" => design.canvas_url,
        "pickedKey" => design.picked_key,
        "directions" => directions_data
      }

      manifest_path = Path.join(design_dir, "manifest.json")
      File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
      {:ok, design_dir}
    end
  end

  defp download_design_directions(directions, design_dir, token, opts) do
    directions
    |> Enum.reduce_while({:ok, []}, fn %DesignDirection{} = dir, {:ok, acc} ->
      filename = "still_#{dir.key}.png"
      dest_path = Path.join(design_dir, filename)

      case maybe_download_file(dir.still_url, dest_path, token, opts) do
        :ok ->
          entry = %{
            "key" => dir.key,
            "title" => dir.title,
            "notes" => dir.notes,
            "still_path" => dest_path
          }

          {:cont, {:ok, [entry | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev_entries} -> {:ok, Enum.reverse(rev_entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp materialize_demo(%Demo{} = demo, dest_scratch_dir, opts) do
    demo_dir =
      if String.ends_with?(dest_scratch_dir, "demo") do
        dest_scratch_dir
      else
        Path.join(dest_scratch_dir, "demo")
      end

    File.mkdir_p!(demo_dir)

    with {:ok, token} <- resolve_token(opts),
         {:ok, segments_data} <- download_demo_segments(demo.segments || [], demo_dir, token, opts) do
      manifest = %{
        "version" => demo.version,
        "outcome" => to_string(demo.outcome),
        "note" => demo.note,
        "segments" => segments_data
      }

      manifest_path = Path.join(demo_dir, "manifest.json")
      File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
      {:ok, demo_dir}
    end
  end

  defp download_demo_segments(segments, demo_dir, token, opts) do
    segments
    |> Enum.reduce_while({:ok, []}, fn %DemoSegment{} = seg, {:ok, acc} ->
      case download_segment_frames(seg, demo_dir, token, opts) do
        {:ok, seg_data} -> {:cont, {:ok, [seg_data | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev_segs} -> {:ok, Enum.reverse(rev_segs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp download_segment_frames(%DemoSegment{} = seg, demo_dir, token, opts) do
    frames = seg.frames || []

    frames
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {%DemoFrame{} = frame, f_idx}, {:ok, acc} ->
      filename = "ac#{seg.criterion_index}_#{f_idx}.png"
      dest_path = Path.join(demo_dir, filename)

      case maybe_download_file(frame.url, dest_path, token, opts) do
        :ok ->
          frame_map = %{
            "path" => filename,
            "holdMs" => frame.hold_ms,
            "caption" => frame.caption
          }

          {:cont, {:ok, [frame_map | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev_frames} ->
        seg_map = %{
          "criterionIndex" => seg.criterion_index,
          "criterion" => seg.criterion,
          "outcome" => to_string(seg.outcome),
          "note" => seg.note,
          "frames" => Enum.reverse(rev_frames)
        }

        {:ok, seg_map}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp materialize_qa_report(%QaReport{} = report, dest_scratch_dir, opts) do
    qa_dir =
      if String.ends_with?(dest_scratch_dir, "qa") do
        dest_scratch_dir
      else
        Path.join(dest_scratch_dir, "qa")
      end

    File.mkdir_p!(qa_dir)

    with {:ok, token} <- resolve_token(opts),
         {:ok, rows_data} <- download_qa_rows(report.rows || [], qa_dir, token, opts) do
      manifest = %{
        "commit" => report.commit,
        "session" => report.session,
        "rows" => rows_data
      }

      manifest_path = Path.join(qa_dir, "manifest.json")
      File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
      {:ok, qa_dir}
    end
  end

  defp download_qa_rows(rows, qa_dir, token, opts) do
    rows
    |> Enum.reduce_while({:ok, []}, fn %QaRow{} = row, {:ok, acc} ->
      case download_row_artifacts(row, qa_dir, token, opts) do
        {:ok, row_data} -> {:cont, {:ok, [row_data | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev_rows} -> {:ok, Enum.reverse(rev_rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp download_row_artifacts(%QaRow{} = row, qa_dir, token, opts) do
    artifacts = row.artifacts || []

    artifacts
    |> Enum.reduce_while({:ok, []}, fn %QaArtifact{} = art, {:ok, acc} ->
      dest_path = Path.join(qa_dir, art.name)

      res =
        cond do
          art.kind == :text and is_binary(art.text) ->
            File.write!(dest_path, art.text)
            :ok

          is_binary(art.url) ->
            maybe_download_file(art.url, dest_path, token, opts)

          true ->
            :ok
        end

      case res do
        :ok ->
          art_map = %{
            "name" => art.name,
            "kind" => to_string(art.kind),
            "text" => art.text,
            "url" => art.url,
            "path" => art.name
          }

          {:cont, {:ok, [art_map | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev_arts} ->
        row_map = %{
          "id" => row.id,
          "check" => row.check,
          "result" => to_string(row.result),
          "severity" => to_string(row.severity),
          "causedByChange" => row.caused_by_change,
          "command" => row.command,
          "exitCode" => row.exit_code,
          "note" => row.note,
          "artifacts" => Enum.reverse(rev_arts)
        }

        {:ok, row_map}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_download_file(nil, _dest_path, _token, _opts), do: :ok
  defp maybe_download_file("", _dest_path, _token, _opts), do: :ok

  defp maybe_download_file(url, dest_path, token, opts) do
    req_options =
      Application.get_env(:rail, :linear, [])[:req_options] || []

    custom_opts = Keyword.get(opts, :req_options, [])

    req =
      [retry: false]
      |> Req.new()
      |> Req.merge(req_options)
      |> Req.merge(custom_opts)

    headers = [{"authorization", token}]

    case Req.get(req, url: url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        File.write!(dest_path, body)
        :ok

      {:ok, %{status: status}} ->
        {:error, {:download_failed, status, url}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_token(opts) do
    case Keyword.get(opts, :token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _nil ->
        target = Keyword.get(opts, :workspace) || Keyword.get(opts, :project)
        workspace_token(target)
    end
  end

  defp workspace_token(%LinearWorkspace{token: token}) when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp workspace_token(%Project{linear_workspace: %LinearWorkspace{token: token}})
       when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp workspace_token(%Project{linear_workspace_id: ws_id}) when is_binary(ws_id) do
    case Repo.get(LinearWorkspace, ws_id) do
      %LinearWorkspace{token: token} when is_binary(token) and token != "" ->
        {:ok, token}

      _other ->
        {:error, :no_workspace_token}
    end
  end

  defp workspace_token(_fallback) do
    case Repo.one(from lw in LinearWorkspace, limit: 1) do
      %LinearWorkspace{token: token} when is_binary(token) and token != "" ->
        {:ok, token}

      _other ->
        {:error, :no_workspace_token}
    end
  end
end
