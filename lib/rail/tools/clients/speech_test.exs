defmodule Rail.Tools.Clients.SpeechTest do
  use Rail.DataCase, async: true

  alias Rail.Tools.Clients.Speech

  @audio %{"inlineData" => %{"mimeType" => "audio/L16;codec=pcm;rate=24000", "data" => Base.encode64("pcm bytes")}}

  setup do
    stub(Rail, :goth_enabled?, fn -> true end)
    stub(Goth, :fetch, fn Rail.Goth -> {:ok, %Goth.Token{token: "test_token"}} end)
    stub(Goth.Config, :get, fn :project_id -> {:ok, "rail-testing"} end)
    :ok
  end

  test "speaks the caption alone, in a presenter's voice, at the global endpoint under Goth's project, as raw PCM" do
    Req.Test.expect(Speech, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.request_path ==
               "/v1/projects/rail-testing/locations/global/publishers/google/models/gemini-3.8-flash-tts:generateContent"

      assert ["Bearer test_token"] = Plug.Conn.get_req_header(conn, "authorization")

      # Gemini 3.8 reads the text word for word, so a direction in front of the caption would be spoken too.
      assert %{
               "contents" => [
                 %{"parts" => [%{"text" => "Saved exactly as entered.", "speech_metadata" => %{"style" => style}}]}
               ],
               "generationConfig" => %{
                 "responseModalities" => ["AUDIO"],
                 "speechConfig" => %{"voiceConfig" => %{"prebuiltVoiceConfig" => %{"voiceName" => "Achird"}}}
               }
             } = Jason.decode!(body)

      assert style =~ "friendly engineer showing a teammate"
      assert style =~ "varied intonation"
      Req.Test.json(conn, %{"candidates" => [%{"content" => %{"parts" => [@audio]}}]})
    end)

    assert {:ok, "pcm bytes"} = Speech.synthesize("Saved exactly as entered.")
    assert Speech.rate() == 24_000
  end

  test "a WAV answer is its 24 kHz mono 16-bit data chunk, past any chunk beside it" do
    mono = <<1::little-16, 1::little-16, 24_000::little-32, 48_000::little-32, 2::little-16, 16::little-16>>

    wav =
      <<"RIFF", 0::little-32, "WAVE", "fmt ", 16::little-32, mono::binary, "LIST", 3::little-32, "abc", 0, "data",
        9::little-32, "pcm bytes", "C2PA", 2::little-32, "id">>

    audio = %{"inlineData" => %{"mimeType" => "audio/wav", "data" => Base.encode64(wav)}}
    Req.Test.stub(Speech, &Req.Test.json(&1, %{"candidates" => [%{"content" => %{"parts" => [audio]}}]}))

    assert {:ok, "pcm bytes"} = Speech.synthesize("Line.")
  end

  test "an answer with no audio, audio of another format, or an error status is an error" do
    Req.Test.stub(Speech, &Req.Test.json(&1, %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "hi"}]}}]}))
    assert {:error, :no_audio} = Speech.synthesize("Line.")

    mp3 = %{"inlineData" => %{"mimeType" => "audio/mpeg", "data" => ""}}
    Req.Test.stub(Speech, &Req.Test.json(&1, %{"candidates" => [%{"content" => %{"parts" => [mp3]}}]}))
    assert {:error, {:unexpected_audio, "audio/mpeg"}} = Speech.synthesize("Line.")

    stereo = <<1::little-16, 2::little-16, 24_000::little-32, 96_000::little-32, 4::little-16, 16::little-16>>

    for data <- [
          "",
          <<"RIFF", 0::little-32, "WAVE", "fmt ", 16::little-32, stereo::binary, "data", 3::little-32, "pcm">>,
          <<"RIFF", 0::little-32, "WAVE", "data", 9::little-32, "pcm">>
        ] do
      wav = %{"inlineData" => %{"mimeType" => "audio/wav", "data" => Base.encode64(data)}}
      Req.Test.stub(Speech, &Req.Test.json(&1, %{"candidates" => [%{"content" => %{"parts" => [wav]}}]}))
      assert {:error, {:unexpected_audio, "audio/wav"}} = Speech.synthesize("Line.")
    end

    Req.Test.stub(Speech, &Plug.Conn.send_resp(&1, 429, "slow down"))
    assert {:error, {:speech_error, 429, "slow down"}} = Speech.synthesize("Line.")

    Req.Test.stub(Speech, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, %Req.TransportError{reason: :econnrefused}} = Speech.synthesize("Line.")
  end

  test "with Goth off, failing, or with no project it returns an error and sends nothing" do
    Req.Test.stub(Speech, fn _conn -> flunk("a request was sent without a token") end)

    stub(Goth, :fetch, fn Rail.Goth -> exit(:timeout) end)
    assert {:error, {:goth_unavailable, :timeout}} = Speech.synthesize("Line.")

    stub(Goth, :fetch, fn Rail.Goth -> {:error, :refused} end)
    assert {:error, {:goth_unavailable, :refused}} = Speech.synthesize("Line.")

    stub(Goth, :fetch, fn Rail.Goth -> {:ok, %Goth.Token{token: "test_token"}} end)
    stub(Goth.Config, :get, fn :project_id -> :error end)
    assert {:error, :no_project_id} = Speech.synthesize("Line.")

    stub(Goth.Config, :get, fn :project_id -> raise "no credentials" end)
    assert {:error, {:goth_unavailable, %RuntimeError{}}} = Speech.synthesize("Line.")

    stub(Rail, :goth_enabled?, fn -> false end)
    assert {:error, :goth_disabled} = Speech.synthesize("Line.")
  end
end
