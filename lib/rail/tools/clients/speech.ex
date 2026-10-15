defmodule Rail.Tools.Clients.Speech do
  @moduledoc """
  Speaks a line with Gemini's text-to-speech on Vertex AI, on the token and project Goth holds, at the global
  endpoint. What comes back is raw 16-bit mono PCM at 24 kHz, which is what the demo's voice-over is mixed from.
  """

  @model "gemini-3.8-flash-tts"
  @voice "Kore"
  @rate 24_000

  @doc "The sample rate every line is spoken at."
  def rate, do: @rate

  @doc """
  Speaks `text` as a calm narrator. Returns `{:ok, pcm}`, or an error without a request when Goth is off.
  """
  def synthesize(text) when is_binary(text) do
    if Rail.goth_enabled?(), do: request(text), else: {:error, :goth_disabled}
  end

  defp request(text) do
    with {:ok, token} <- token(),
         {:ok, project_id} <- project_id() do
      [
        base_url: "https://aiplatform.googleapis.com/v1",
        url: "/projects/#{project_id}/locations/global/publishers/google/models/#{@model}:generateContent",
        auth: {:bearer, token},
        json: %{
          contents: [%{role: "user", parts: [%{text: "Say in a calm, clear product-demo voice: #{text}"}]}],
          generationConfig: %{
            responseModalities: ["AUDIO"],
            speechConfig: %{voiceConfig: %{prebuiltVoiceConfig: %{voiceName: @voice}}}
          }
        }
      ]
      |> Req.post(Keyword.get(Application.get_env(:rail, :speech, []), :req_options, []))
      |> case do
        {:ok, %{status: 200, body: %{"candidates" => [%{"content" => %{"parts" => parts}} | _rest]}}} -> audio(parts)
        {:ok, %{status: status, body: body}} -> {:error, {:speech_error, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp audio(parts) do
    case Enum.find(parts, &match?(%{"inlineData" => %{"data" => _data}}, &1)) do
      %{"inlineData" => %{"data" => data, "mimeType" => "audio/L16;codec=pcm;rate=24000"}} -> Base.decode64(data)
      %{"inlineData" => %{"data" => data, "mimeType" => "audio/wav"}} -> data |> Base.decode64!() |> wav_pcm()
      %{"inlineData" => %{"mimeType" => other}} -> {:error, {:unexpected_audio, other}}
      nil -> {:error, :no_audio}
    end
  end

  # The same PCM wrapped in a WAV, with provenance chunks beside it; only its data chunk is the voice.
  defp wav_pcm(<<"RIFF", _size::little-32, "WAVE", chunks::binary>>), do: wav_pcm(chunks, nil)
  defp wav_pcm(_other), do: {:error, {:unexpected_audio, "audio/wav"}}

  defp wav_pcm(<<"fmt ", size::little-32, format::binary-size(size), rest::binary>>, _format), do: wav_pcm(rest, format)

  defp wav_pcm(<<"data", size::little-32, pcm::binary-size(size), _rest::binary>>, format) do
    case format do
      <<1::little-16, 1::little-16, @rate::little-32, _byte_rate::little-32, _align::little-16, 16::little-16,
        _extra::binary>> ->
        {:ok, pcm}

      _other_format ->
        {:error, {:unexpected_audio, "audio/wav"}}
    end
  end

  # A chunk is padded to an even length.
  defp wav_pcm(<<_id::binary-4, size::little-32, rest::binary>>, format) when byte_size(rest) >= size + rem(size, 2) do
    <<_chunk::binary-size(size + rem(size, 2)), rest::binary>> = rest
    wav_pcm(rest, format)
  end

  defp wav_pcm(_truncated, _format), do: {:error, {:unexpected_audio, "audio/wav"}}

  # Goth exits when its server is slow or gone and raises when no credentials resolve; either is a line that
  # cannot be spoken, not a crash for the encode.
  defp token do
    case Goth.fetch(Rail.Goth) do
      {:ok, %{token: token}} -> {:ok, token}
      {:error, reason} -> {:error, {:goth_unavailable, reason}}
    end
  catch
    :exit, reason -> {:error, {:goth_unavailable, reason}}
  end

  defp project_id do
    case Goth.Config.get(:project_id) do
      {:ok, project_id} when is_binary(project_id) -> {:ok, project_id}
      _missing -> {:error, :no_project_id}
    end
  rescue
    exception -> {:error, {:goth_unavailable, exception}}
  end
end
