defmodule Rail.Artifacts.Validators.QaValidator do
  @moduledoc """
  Validates agent-produced QA manifests, test sessions, check rows, and evidence artifacts.
  """

  import Rail.Artifacts.Utils.PathConfinement

  @doc """
  Validates a QA directory containing `manifest.json` and artifact files.
  """
  def validate(qa_dir, _opts \\ []) when is_binary(qa_dir) do
    manifest_path = Path.join(qa_dir, "manifest.json")

    with {:ok, content} <- read_file(manifest_path),
         {:ok, data} <- parse_json(content),
         {:ok, session} <- validate_session(data["session"]),
         {:ok, raw_rows} <- fetch_rows(data),
         {:ok, rows} <- validate_rows(qa_dir, raw_rows) do
      commit = sanitize_string(data["commit"])

      {:ok,
       %{
         session: session,
         commit: commit,
         rows: rows
       }}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, "QA manifest not found at #{path}."}
    end
  end

  defp parse_json(content) do
    case Jason.decode(content) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _not_map} -> {:error, "QA manifest must be a JSON object."}
      {:error, _reason} -> {:error, "Failed to parse QA manifest: invalid JSON."}
    end
  end

  defp validate_session(session) when is_map(session), do: {:ok, session}
  defp validate_session(_other), do: {:error, "QA manifest missing valid \"session\" map."}

  defp fetch_rows(data) do
    case Map.get(data, "rows") do
      rows when is_list(rows) -> {:ok, rows}
      _other -> {:error, "QA manifest missing \"rows\" list."}
    end
  end

  defp validate_rows(qa_dir, raw_rows) do
    raw_rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, idx}, {:ok, acc} ->
      case validate_single_row(qa_dir, idx, row) do
        {:ok, validated_row} -> {:cont, {:ok, [validated_row | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_single_row(qa_dir, idx, row) when is_map(row) do
    id = sanitize_string(row["id"])
    check = sanitize_string(row["check"])
    raw_result = to_string(row["result"] || "")
    raw_severity = to_string(row["severity"] || "")

    with :ok <- validate_row_fields(idx, id, check),
         {:ok, result_atom} <- validate_row_result(idx, raw_result),
         {:ok, severity_atom} <- validate_row_severity(idx, raw_severity),
         {:ok, artifacts} <- validate_artifacts(qa_dir, idx, Map.get(row, "artifacts", [])) do
      caused_by_change = Map.get(row, "caused_by_change", Map.get(row, "causedByChange", true))
      caused_by_change = if is_boolean(caused_by_change), do: caused_by_change, else: true

      validated = %{
        id: id,
        check: check,
        result: result_atom,
        severity: severity_atom,
        caused_by_change: caused_by_change,
        command: sanitize_string(row["command"]),
        exit_code: parse_integer(row["exit_code"] || row["exitCode"]),
        note: sanitize_string(row["note"]),
        artifacts: artifacts
      }

      {:ok, validated}
    end
  end

  defp validate_single_row(_qa_dir, idx, _row) do
    {:error, "QA row at index #{idx} must be an object."}
  end

  defp validate_row_fields(idx, id, check) do
    if is_binary(id) and id != "" and is_binary(check) and check != "" do
      :ok
    else
      {:error, "QA row at index #{idx} missing required fields (id, check)."}
    end
  end

  defp validate_row_result(_idx, "pass"), do: {:ok, :pass}
  defp validate_row_result(_idx, "fail"), do: {:ok, :fail}
  defp validate_row_result(_idx, "skip"), do: {:ok, :skip}
  defp validate_row_result(idx, result), do: {:error, "QA row at index #{idx} has invalid result: \"#{result}\"."}

  defp validate_row_severity(_idx, "blocker"), do: {:ok, :blocker}
  defp validate_row_severity(_idx, "critical"), do: {:ok, :critical}
  defp validate_row_severity(_idx, "major"), do: {:ok, :major}
  defp validate_row_severity(_idx, "minor"), do: {:ok, :minor}
  defp validate_row_severity(_idx, "cosmetic"), do: {:ok, :cosmetic}
  defp validate_row_severity(_idx, "nit"), do: {:ok, :cosmetic}
  defp validate_row_severity(idx, severity), do: {:error, "QA row at index #{idx} has invalid severity: \"#{severity}\"."}

  defp validate_artifacts(qa_dir, row_idx, artifacts) when is_list(artifacts) do
    artifacts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {art, art_idx}, {:ok, acc} ->
      case validate_artifact(qa_dir, row_idx, art_idx, art) do
        {:ok, validated_art} -> {:cont, {:ok, [validated_art | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_artifacts(_qa_dir, row_idx, _artifacts) do
    {:error, "QA row at index #{row_idx} artifacts must be a list."}
  end

  defp validate_artifact(qa_dir, row_idx, art_idx, art) when is_map(art) do
    name = sanitize_string(art["name"])
    raw_kind = to_string(art["kind"] || "")
    raw_path = art["path"]

    with :ok <- validate_artifact_required(row_idx, art_idx, name),
         {:ok, kind_atom} <- validate_artifact_kind(row_idx, art_idx, raw_kind),
         {:ok, resolved_path} <- verify_artifact_path(qa_dir, raw_path) do
      validated = %{
        name: name,
        kind: kind_atom,
        text: sanitize_string(art["text"]),
        url: sanitize_string(art["url"]),
        path: raw_path,
        resolved_path: resolved_path
      }

      {:ok, validated}
    end
  end

  defp validate_artifact(_qa_dir, row_idx, art_idx, _art) do
    {:error, "QA row #{row_idx} artifact #{art_idx} must be an object."}
  end

  defp validate_artifact_required(row_idx, art_idx, name) do
    if is_binary(name) and name != "" do
      :ok
    else
      {:error, "QA row #{row_idx} artifact #{art_idx} is missing a name."}
    end
  end

  defp validate_artifact_kind(_row_idx, _art_idx, "text"), do: {:ok, :text}
  defp validate_artifact_kind(_row_idx, _art_idx, "image"), do: {:ok, :image}

  defp validate_artifact_kind(row_idx, art_idx, kind),
    do: {:error, "QA row #{row_idx} artifact #{art_idx} has invalid kind: \"#{kind}\"."}

  defp verify_artifact_path(_qa_dir, nil), do: {:ok, nil}

  defp verify_artifact_path(qa_dir, raw_path) when is_binary(raw_path) do
    case verify_confinement(qa_dir, raw_path, allow_root: false) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, :escapes_confinement} -> {:error, "QA artifact path escapes qa directory: #{raw_path}"}
    end
  end

  defp sanitize_string(str) when is_binary(str), do: String.trim(str)
  defp sanitize_string(_other), do: nil

  defp parse_integer(val) when is_integer(val), do: val

  defp parse_integer(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp parse_integer(_other), do: nil
end
