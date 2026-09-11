defmodule Rail.Artifacts.Validators.DesignValidator do
  @moduledoc """
  Validates agent-produced design manifests, stills, and live canvas URLs in scratch storage.
  """

  import Rail.Artifacts.Utils.PathConfinement
  import Rail.Artifacts.Utils.UrlProbe

  @doc """
  Validates a design directory containing `manifest.json` and still image files.
  """
  def validate(design_dir, opts \\ []) when is_binary(design_dir) do
    manifest_path = Path.join(design_dir, "manifest.json")

    with {:ok, content} <- read_file(manifest_path),
         {:ok, data} <- parse_json(content),
         {:ok, canvas_url} <- validate_canvas_url(data["canvasUrl"]),
         {:ok, raw_directions} <- fetch_directions(data),
         {:ok, directions} <- validate_directions(design_dir, raw_directions),
         :ok <- probe_canvas_url(canvas_url, opts) do
      version = parse_version(data["version"])
      picked_key = sanitize_string(data["pickedKey"])

      {:ok,
       %{
         version: version,
         canvas_url: canvas_url,
         picked_key: picked_key,
         directions: directions
       }}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, "No design manifest found at #{path}."}
    end
  end

  defp parse_json(content) do
    case Jason.decode(content) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _not_map} -> {:error, "Invalid design manifest: expected a JSON object."}
      {:error, _reason} -> {:error, "Failed to parse design manifest: invalid JSON."}
    end
  end

  defp parse_version(v) when is_integer(v) and v >= 1, do: v
  defp parse_version(v) when is_float(v) and v >= 1.0, do: trunc(v)
  defp parse_version(_other), do: 1

  defp sanitize_string(str) when is_binary(str), do: String.trim(str)
  defp sanitize_string(_other), do: nil

  defp validate_canvas_url(nil), do: {:error, "Design manifest is missing a canvasUrl."}

  defp validate_canvas_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    if trimmed == "" do
      {:error, "Design manifest is missing a canvasUrl."}
    else
      uri = URI.parse(trimmed)

      if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" do
        {:ok, trimmed}
      else
        {:error, "Design manifest canvasUrl must be an absolute https URL."}
      end
    end
  end

  defp validate_canvas_url(_other), do: {:error, "Design manifest is missing a canvasUrl."}

  defp fetch_directions(data) do
    case Map.get(data, "directions") do
      dirs when is_list(dirs) and dirs != [] ->
        {:ok, dirs}

      _other ->
        {:error, "Design manifest must contain at least one design direction."}
    end
  end

  defp validate_directions(design_dir, raw_directions) do
    raw_directions
    |> Enum.reduce_while({:ok, []}, fn raw_dir, {:ok, acc} ->
      case validate_direction(design_dir, raw_dir) do
        {:ok, dir} -> {:cont, {:ok, [dir | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, dirs} -> {:ok, Enum.reverse(dirs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_direction(design_dir, raw_dir) when is_map(raw_dir) do
    key = sanitize_string(raw_dir["key"])
    title = sanitize_string(raw_dir["title"])
    notes = sanitize_string(raw_dir["notes"])
    raw_still_path = raw_dir["still_path"] || raw_dir["stillPath"]

    if non_blank?(key) and non_blank?(title) and non_blank?(notes) and is_binary(raw_still_path) and
         String.trim(raw_still_path) != "" do
      validate_still_path(design_dir, key, title, notes, String.trim(raw_still_path))
    else
      {:error, "Direction entry missing required fields (key, title, notes, stillPath)."}
    end
  end

  defp validate_direction(_design_dir, _raw_dir) do
    {:error, "Invalid direction entry in design manifest: expected an object."}
  end

  defp non_blank?(str) when is_binary(str), do: str != ""
  defp non_blank?(_other), do: false

  # A still is written next to the manifest, in the task's design directory. Nothing
  # outside it is a design Rail captures.
  defp validate_still_path(design_dir, key, title, notes, raw_still_path) do
    canonical_target =
      if Path.type(raw_still_path) == :absolute do
        Path.expand(raw_still_path)
      else
        Path.expand(raw_still_path, design_dir)
      end

    case verify_confinement(design_dir, canonical_target, allow_root: false) do
      {:ok, canonical_path} ->
        case File.stat(canonical_path) do
          {:ok, %{type: :regular, size: size}} when size > 0 ->
            direction = %{
              key: key,
              title: title,
              notes: notes,
              still_path: canonical_path
            }

            {:ok, direction}

          _other ->
            {:error, "Design still image not found or empty at #{raw_still_path}."}
        end

      {:error, :escapes_confinement} ->
        {:error, "Design still image path must stay inside .rail/design/: #{raw_still_path}."}
    end
  end

  defp probe_canvas_url(canvas_url, opts) do
    if probe(canvas_url, opts) do
      :ok
    else
      {:error, "Canvas URL could not be opened or returned 404/410: #{canvas_url}."}
    end
  end
end
