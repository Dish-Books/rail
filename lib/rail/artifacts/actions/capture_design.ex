defmodule Rail.Artifacts.Actions.CaptureDesign do
  @moduledoc false

  import Ecto.Query
  import Rail.Artifacts.Utils.CommentFormatter
  import Rail.Artifacts.Utils.MimeType

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Artifacts.Validators.DesignValidator
  alias Rail.Issues
  alias Rail.Repo

  def capture_design(scope, target, scratch_dir_or_opts, opts \\ []) do
    {task_id, scratch_dir, combined_opts} = normalize_args(target, scratch_dir_or_opts, opts)
    do_capture_design(scope, task_id, scratch_dir, combined_opts)
  end

  defp normalize_args(target, scratch_dir, opts) when is_binary(scratch_dir) do
    task_id = extract_task_id(target)
    {task_id, scratch_dir, opts}
  end

  defp normalize_args(target, opts, _extra_opts) when is_list(opts) do
    task_id = extract_task_id(target)
    scratch_dir = Keyword.get(opts, :scratch_dir) || "/tmp/rail_scratch/#{task_id}"
    {task_id, scratch_dir, opts}
  end

  defp extract_task_id(%{id: task_id}), do: to_string(task_id)
  defp extract_task_id(task_id) when is_binary(task_id), do: task_id
  defp extract_task_id(other), do: to_string(other)

  defp do_capture_design(scope, task_id, scratch_dir, opts) do
    design_dir = resolve_design_dir(scratch_dir)

    with {:ok, design_data} <- DesignValidator.validate(design_dir, opts),
         {:ok, directions_with_assets} <- upload_design_assets(scope, design_data.directions, opts) do
      version = next_version(task_id, design_data[:version])

      design_attrs = %{
        task_id: task_id,
        version: version,
        canvas_url: design_data[:canvas_url],
        picked_key: design_data[:picked_key],
        directions: directions_with_assets
      }

      design_struct = struct(Design, design_attrs)

      with {:ok, comment_id} <- maybe_post_comment(scope, design_struct, opts) do
        final_attrs =
          if comment_id do
            Map.put(design_attrs, :linear_comment_id, comment_id)
          else
            design_attrs
          end

        %Design{}
        |> Design.changeset(final_attrs)
        |> Repo.insert()
      end
    end
  end

  defp resolve_design_dir(path) do
    cond do
      File.exists?(Path.join(path, "manifest.json")) -> path
      File.exists?(Path.join([path, "design", "manifest.json"])) -> Path.join(path, "design")
      File.exists?(Path.join([path, ".axis", "design", "manifest.json"])) -> Path.join([path, ".axis", "design"])
      true -> Path.join(path, "design")
    end
  end

  defp next_version(task_id, manifest_version) do
    query =
      from d in Design,
        where: d.task_id == ^task_id,
        order_by: [desc: d.version],
        limit: 1,
        select: d.version

    case Repo.one(query) do
      latest when is_integer(latest) -> max(latest + 1, manifest_version || 1)
      nil -> manifest_version || 1
    end
  end

  defp upload_design_assets(scope, directions, opts) do
    directions
    |> Enum.reduce_while({:ok, []}, fn dir_entry, {:ok, acc} ->
      case upload_direction_still(scope, dir_entry, opts) do
        {:ok, updated_dir} -> {:cont, {:ok, [updated_dir | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev_dirs} -> {:ok, Enum.reverse(rev_dirs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upload_direction_still(scope, dir_entry, opts) do
    still_path = dir_entry[:still_path] || dir_entry["still_path"]
    filename = Path.basename(still_path)

    case File.read(still_path) do
      {:ok, binary} ->
        content_type = mime_type(filename)

        case Issues.upload_asset(scope, filename, content_type, binary, opts) do
          {:ok, %{asset_url: asset_url, asset_id: asset_id}} ->
            updated =
              dir_entry
              |> Map.put(:still_url, asset_url)
              |> Map.put(:linear_asset_id, asset_id)

            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, "Failed to read design still #{still_path}: #{inspect(reason)}"}
    end
  end

  defp maybe_post_comment(scope, design_struct, opts) do
    issue = Keyword.get(opts, :issue)

    if issue do
      comment_body = format_design_comment(design_struct)
      owner_user = Keyword.get(opts, :owner_user)

      case Issues.comment(scope, issue, comment_body, owner_user) do
        {:ok, %{id: comment_id}} -> {:ok, comment_id}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, nil}
    end
  end
end
